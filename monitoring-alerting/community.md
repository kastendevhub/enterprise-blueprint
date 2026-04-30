# Goal 

This is an end to end guide for integrating Kasten with the prometheus community stack.

I did this guide with 
- kasten version 7.0.7 
- Prometheus chart kube-prometheus-stack-62.6.0 and App version v0.76.1 (which is the version of prometheus operator) 
- kubernetes v1.28.12 (on eks)

Any other version may need to adapt this guide. 

This guide do not cover the installation of eks and kasten, they are supposed to be prerequisite.

# Warning 

This guide is just informative and neither I or Veeam would be liable for any issues that may results following this guide. 

You should first test it on a test environment that have no conscequences for your buisness continuity. 

# Install prometheus community stack

```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prom prometheus-community/kube-prometheus-stack --create-namespace -n monitoring 
```

# The defaut installation 

What we did above is a default installation of the community prometheus stack in which prometheus 
and alertmanager are configured to detect the `ScrapeConfig` and `PrometheusRule`
custom resource that has the labels `release=prom`.
It's why you'll see this label for the `scrapeConfig` and `PrometheusRule` resources.

Edit alertmanager 
```
kubectl edit alertmanager -n monitoring
```

And set `forceEnableClusterMode: true` under `spec`. Because if there is not at least 2 replicas 
alertmanager has the status disabled. Alternatively change the number of replicas to 2 should 
also change the status of alertmanager.

So that later the AlertManagerConfig CR will be used by AlertManager 

# Access the UI 

There is no real need to expose publically the UI and only administrator will work with thoses UI.

Execute :
```
kubectl port-forward -n monitoring service/prom-kube-prometheus-stack-prometheus 9090:9090
```
Go to the prometheus UI  http://localhost:9090


Execute  
```
kubectl port-forward -n monitoring service/prom-kube-prometheus-stack-alertmanager 9093:9093
```
Go to the alertmanager UI http://localhost:9093


# Deploy the scrape config for kasten 

Before deploying the scape configs make sure you allow monitoring namespace to access kasten-io namespace.

```
cat<<EOF | kubectl create -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  namespace: kasten-io
  name: allow-external-monitoring
spec:
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: monitoring
  podSelector:
    matchLabels:
      release: k10
EOF
```

Let's create the scrape config.
```
kubectl create -f kasten-scrape-config.yaml
```

We suppose kasten is deployed on `kasten-io` namespace if this is not the case 
adapt in the scrapeConfig the part `httpSDConfigs.url` and the namespace of the 
scrapeConfig.

To check your scrape configs are up, go in the [prometheus UI > Status > targets](http://localhost:9090/targets?search=) 
and check that now you have 2 new target groups:
- scrapeConfig/kasten-io/k10-executor-discovery
- scrapeConfig/kasten-io/k10-http-service-discovery

And that each targets inside the group is up.

# Deploy the kasten prometeus rule 

```
kubectl create -f kasten-rules.yaml 
```

It contains 5 rules also deployed in kasten-io:

- catalog-over-50-percent: check that the size of catalog is not over 50% which would block future 
update in case of schema upgrade of the catalog. It's severity is `warning` has it is not an immediate
danger for your backups.
- action-on-error: probably the most important, it detects an action failed whatever the action but most 
of the time it's `export` or `backup` action. It's severity is `critical` because then you may be not 
protected anymore.
- license-non-compliant: check if your license pool is consistent with your cluster. If it is not the case
 you have a grace period of 50 days to remediate. Hence the severity is `warning` as your backups are not 
 immediately at risk.
- kasten-service-down and kasten-executor-down: detect if one of the kasten service or one of the kasten 
executor is down. If that happens it's a very bad sign and 
- kasten-event-group: different global events that kasten can send, for instance kasten has detected that an
an attempt to tamper an immutable backup has been done or a policy does not validate anymore.

To check your rules are properly deployed go in the prometheus UI > Status > Rules and check that you have 
an entry `./kasten.rules`. Check that the rules are OK, you should see the last evaluation of the rules.
Seeing ok does not mean that all is ok. You may have a rule that is sending an alert. But ok means that the 
expression was evaluated properly.  

# Check the alert are firing properly

Before configuring alertmanager we need to check first that alert are fired properly by the rules.

To check the alerts are firing properly were going to test 2 criticals rules : 
- action-on-error
- kasten-service-down

## Action on error 

Creating backup on error is simple you just have to create a failed workload that you backup regulary 
for instance every 5 minutes: 
```
kubectl create ns failed-ns 
# This deployment will never be ready because the image nginxxxx does not exit
kubectl create deployment --image nginxxxx --namespace failed-ns nginx
```

Now create a backup policy to protect this namespace :
```
cat <<EOF | kubectl create -f - 
kind: Policy
apiVersion: config.kio.kasten.io/v1alpha1
metadata:
  name: failed-ns-backup
  namespace: failed-ns  
spec:
  frequency: "@hourly"
  subFrequency:
    minutes:
      - 0
      - 10
      - 5
      - 15
      - 20
      - 25
      - 30
      - 35
      - 40
      - 45
      - 50
      - 55
    hours:
      - 0
    weekdays:
      - 0
    days:
      - 1
    months:
      - 1
  retention:
    hourly: 24
    daily: 7
    weekly: 4
    monthly: 12
    yearly: 7
  selector:
    matchExpressions:
      - key: k10.kasten.io/appNamespace
        operator: In
        values:
          - failed-ns
  actions:
    - action: backup  
EOF
```

After 15 minutes check in [Prometheus UI > Alerts > Firing](http://localhost:9090/alerts?search=) 
and you should see the action-on-error alert firing. Unfold it to see all the labels associated 
with the alert, those labels were copied from the metrics `catalog_actions_count`.

## Kasten service is down 

This is a very simple alert to test: just scaledown a kasten service 
```
kubectl --namespace kasten-io scale deploy metering-svc --replicas 0
```

After few seconds check in [Prometheus UI > Alerts > Firing](http://localhost:9090/alerts?search=) and you should see the kasten-service-down alert firing.

Scale back 
```
kubectl --namespace kasten-io scale deploy metering-svc --replicas 1
```

# Managing alerts 

So far we have prometheus creating alert and passing them to alert manager but the alert are managed 
by the `null receiver` which is created by default when installing alertmanager.

If you go to the [alertmanager configuration](http://localhost:9093/#/status) you'll see that 
there is a default routing of the alert to the `null receiver`.

```
route:
  receiver: "null"
  group_by:
  - namespace
  continue: false
  routes:
  - receiver: "null"
    matchers:
    - alertname="Watchdog"
    continue: false
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
```

And you can confirm that the action-on-error alert (which is still firing) is routed to this 
`null receiver` by going to the [Alertmanager > UI](http://localhost:9093/#/alerts)

If you unfold the "+ null [ namespace=failed-ns]"  you'll see the label associated to this alert.

Which means that alert manager is doing nothing with this alert it send it to the null receiver.

## The "one receiver per namespace" approach 

The possibility to configure alertmanager can be overwhelming and we want to take a simple approach
which is one receiver per namespace. The idea is that we're going to create an AlertManangerConfig 
resource per namespace that will capture the alert of type action-on-error

Create the alerting for the failed-ns namespace 
```
kubectl create -f kasten-alerting-action-on-error.yaml -n failed-ns
```

Now if you check the global route configuration of alertmanager 
```
route:
  receiver: "null"
  group_by:
  - namespace
  continue: false
  routes:
  - receiver: failed-ns/kasten-alerting/kasten-action-on-error-receiver
    group_by:
    - type
    matchers:
    - alertname="action-on-error"
    - namespace="failed-ns"
    continue: true
    group_wait: 5s
    group_interval: 5m
    repeat_interval: 5h
  - receiver: "null"
    matchers:
    - alertname="Watchdog"
    continue: false
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
```

You can see that a new sub-route has been created with this 2 matchers
```
    matchers:
    - alertname="action-on-error"
    - namespace="failed-ns"
```

The action-on-error will be directed to the `failed-ns/kasten-alerting/kasten-receiver` 
receiver. And you can confirm it by checking the [alerts](http://localhost:9093/#/alerts).

If you unfold the info button you'll see that the description section 
```
"The action of type {{ $labels.type}} executed on policy {{ $labels.policy}} for the namespace {{ $labels.namespace}} is on error."
```
Hes been properly evaluated 

This let you design different type of receiver per namespace. However configuring the receiver 
(slack, webhook, teams ... ) is beyond the scope of this guide. 

## routing the other alerts 

We still need to route properly the other alert : 
- catalog-over-50-percent
- license-non-compliant
- kasten-service-down
- kasten-executor-down

And metrics triggered by them does not have any `namespace` label that's why we add it 
statically on the rules. 

If you observe thoses rules you can see that we purposely add the label `namespace=kasten-io`
```
      labels:
        severity: critical 
        namespace: kasten-io  
```
but did not do that for the `action-on-error` rule.

This provide a simple way to route this error to a specific kasten receiver.

Let's apply it 
```
kubectl create -f kubectl create -f kasten-alerting-operating-kasten.yaml
```
 
The [configuration](http://localhost:9093/#/status) of the routing of alertmanager
```
route:
  receiver: "null"
  group_by:
  - namespace
  continue: false
  routes:
  - receiver: failed-ns/kasten-alerting/kasten-action-on-error-receiver
    group_by:
    - type
    matchers:
    - alertname="action-on-error"
    - namespace="failed-ns"
    continue: true
    group_wait: 5s
    group_interval: 5m
    repeat_interval: 5h
  - receiver: kasten-io/kasten-alerting/kasten-operating-receiver
    group_by:
    - alertname
    matchers:
    - namespace="kasten-io"
    continue: true
    group_wait: 5s
    group_interval: 5m
    repeat_interval: 5h
  - receiver: "null"
    matchers:
    - alertname="Watchdog"
    continue: false
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
```
Show 2 subroutes : 
- failed-ns/kasten-alerting/kasten-action-on-error-receiver which is specific to a namespace
- kasten-io/kasten-alerting/kasten-operating-receiver for the rest

Now if you scale down a kasten service you will see the alert sent to the receiver kasten-io/kasten-alerting/kasten-operating-receiver.

# replacing the internal prometheus by the external prometheus 

To replace the internal prometheus by the external we have to add this option to 
the kasten installation  

```
--set global.prometheus.external.host=prom-kube-prometheus-stack-prometheus.monitoring.svc
--set global.prometheus.external.port="9090"
--set prometheus.server.enabled=false
````

or in a values file 
```
global:
  prometheus:
    external: 
      host: prom-kube-prometheus-stack-prometheus.monitoring.svc
      port: "9090"
prometheus:
  server: 
    enabled: false
```


We need to give to kasten informations about the prometheus instance monitoring him because 
- there is some metrics push (that's why we cannot have an internal and an external prometheus) in the same time
- kasten produce AND also consumes its metrics (for instance catalog size or services up exposed on the dashboard)
- you don't want to duplicate your monitoring resource but that's more convenient than mandatory

