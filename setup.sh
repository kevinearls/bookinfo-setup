#
# Install ServiceMesh and then BookInfo on an OCP Cluster
#
# ServiceMesh install based on https://docs.openshift.com/container-platform/4.5/service_mesh/v1x/installing-ossm.html#installing-ossm-v1x
# BookInfo install based on https://docs.openshift.com/container-platform/4.5/service_mesh/v1x/prepare-to-deploy-applications-ossm.html#ossm-tutorial-bookinfo-overview_deploying-applications-ossm-v1x
# More bookinfo information here: https://istio.io/latest/docs/examples/bookinfo/
# Fault injection: https://istio.io/latest/docs/tasks/traffic-management/fault-injection/

set -x
set -e
#
# TODO: Write a cleanup job
#
export CONTROL_PLANE_NAMESPACE=istio-system
export CONTROL_PLANE_NAME=istio-system
export BOOKINFO_NAMESPACE=bookinfo
export TRAFFIC_GENERATOR_NAMESPACE=traffic

# First install the ES, AMQ Streams (optional?), Jaeger, and Kiali Operators. Currently this will install released versions from redhat-operators
oc create -f elasticsearch-subscription.yaml
oc create -f amq-streams-subscription.yaml
oc create -f jaeger-subscription.yaml
oc create -f kiali-subscription.yaml

# Now wait for those operators to be ready; re-order this by normal expected setup times
sleep 60

# Wait for AMQ Streams
export AMQ_STREAMS_OPERATOR_NAME=$(oc get deployments --all-namespaces | grep amq-streams | awk '{print $2}')
export AMQ_STREAMS_OPERATOR_NAMESPACE=$(oc get deployments --all-namespaces | grep amq-streams | awk '{print $1}')
oc wait --for=condition=available deployment/${AMQ_STREAMS_OPERATOR_NAME} --namespace ${AMQ_STREAMS_OPERATOR_NAMESPACE} --timeout=120s

# Wait for ElasticSearch
export ES_OPERATOR_NAMESPACE=$(oc get deployments --all-namespaces | grep elasticsearch-operator | awk '{print $1}')
oc wait --for=condition=available deployment/elasticsearch-operator --namespace ${ES_OPERATOR_NAMESPACE} --timeout=120s

# Wait for Jaeger
export JAEGER_OPERATOR_NAMESPACE=$(oc get deployments --all-namespaces | grep jaeger-operator | awk '{print $1}')
oc wait --for=condition=available deployment/jaeger-operator --namespace ${JAEGER_OPERATOR_NAMESPACE} --timeout=120s

# Wait for Kiali - should we wait for Jaeger before installing?
export KIALI_OPERATOR_NAME=$(oc get deployments --all-namespaces | grep kiali | awk '{print $2}')
export KIALI_OPERATOR_NAMESPACE=$(oc get deployments --all-namespaces | grep kiali | awk '{print $1}')
oc wait --for=condition=available deployment/${KIALI_OPERATOR_NAME} --namespace ${KIALI_OPERATOR_NAMESPACE} --timeout=120s

# Now install service mesh and wait for it to install
oc apply -f service-mesh-subscription.yaml
# TODO we might be able to reduce this wait time
sleep 60
export RHSM_OPERATOR_NAME=$(oc get deployments --all-namespaces | grep istio | awk '{print $2}')
export RHSM_OPERATOR_NAMESPACE=$(oc get deployments --all-namespaces | grep istio | awk '{print $1}')
oc wait --for=condition=available deployment/${RHSM_OPERATOR_NAME} --namespace ${RHSM_OPERATOR_NAMESPACE} --timeout=120s

# Create a control plane and service mesh member roll
### Who creates this???
set +e
oc new-project ${CONTROL_PLANE_NAMESPACE} || true
set -e
oc create -f service-mesh-control-plane.yaml

sleep 30
start_time=`date +%s`
set +e
maxtime="5 minute"
endtime=$(date -ud "$maxtime" +%s)
while [[ $(date -u +%s) -le $endtime ]]
do
    STATUS=$(oc get smcp istio-system --namespace ${CONTROL_PLANE_NAMESPACE} | grep istio-system | awk '{print $3}')
    echo control plane istio-system status: ${STATUS}
    if [ "${STATUS}" == "InstallSuccessful" ] ; then
        oc get smcp --namespace ${CONTROL_PLANE_NAMESPACE}
        break;
    fi
    sleep 10
done
set -e

# HACK make sure we haven't fallen thru the loop above because of time out.  TODO Maybe check STATUS instead?
oc get smcp --namespace ${CONTROL_PLANE_NAMESPACE}
oc get deployments --namespace ${CONTROL_PLANE_NAMESPACE}
oc wait --for=condition=available deployment/istio-egressgateway --namespace ${CONTROL_PLANE_NAMESPACE}

# TODO do we need to wait for the Jaeger instance to be ready? Yes, because we need to wait for the ES instane to start
sleep 60
export JAEGER_OPERATOR_NAMESPACE=$(oc get deployments --all-namespaces | grep jaeger-operator | awk '{print $1}')
oc wait --for=condition=available deployment/jaeger-operator --namespace ${JAEGER_OPERATOR_NAMESPACE} --timeout=120s


oc apply --namespace ${CONTROL_PLANE_NAMESPACE} -f service-mesh-member-roll.yaml

# Install bookinfo
oc new-project ${BOOKINFO_NAMESPACE}
# OR https://raw.githubusercontent.com/istio/istio/master/samples/bookinfo/platform/kube/bookinfo.yaml ????
oc apply -n ${BOOKINFO_NAMESPACE} -f https://raw.githubusercontent.com/Maistra/istio/maistra-1.1/samples/bookinfo/platform/kube/bookinfo.yaml

sleep 30
for deployment in details-v1 productpage-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3 ; do
    oc wait --for=condition=available deployment/${deployment} --namespace ${BOOKINFO_NAMESPACE} --timeout=120s
done

oc apply -n ${BOOKINFO_NAMESPACE} -f https://raw.githubusercontent.com/Maistra/istio/maistra-1.1/samples/bookinfo/networking/bookinfo-gateway.yaml

## TODO Do we need this?  Would it be better to create a route like Filip does?
export GATEWAY_URL=$(oc -n ${CONTROL_PLANE_NAMESPACE} get route istio-ingressgateway -o jsonpath='{.spec.host}')
echo GATEWAY_URL is ${GATEWAY_URL}

oc apply -n ${BOOKINFO_NAMESPACE} -f https://raw.githubusercontent.com/Maistra/istio/maistra-1.1/samples/bookinfo/networking/destination-rule-all.yaml

# TODO we either need to wait or retry here.Verify that it is installed -it should return a 200
sleep 30
curl -o /dev/null -s -w "%{http_code}\n" http://$GATEWAY_URL/productpage

# Now install the traffic generator.  We need to create the configmap first
# Set duration to "0s" for traffic to never end.  Set RATE to number of operations per second.  Default is per second, we can use something like 1/10s to run every 10 seconds
DURATION="30s"
RATE="1/5s"
ROUTE="http://$GATEWAY_URL/productpage"
oc new-project ${TRAFFIC_GENERATOR_NAMESPACE}
curl https://raw.githubusercontent.com/kiali/kiali-test-mesh/master/traffic-generator/openshift/traffic-generator-configmap.yaml | DURATION="${DURATION}" ROUTE="$ROUTE" RATE="$RATE"  envsubst | oc apply -n ${TRAFFIC_GENERATOR_NAMESPACE} -f -
curl https://raw.githubusercontent.com/kiali/kiali-test-mesh/master/traffic-generator/openshift/traffic-generator.yaml | oc apply -n ${TRAFFIC_GENERATOR_NAMESPACE} -f -





