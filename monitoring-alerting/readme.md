# Goal 

A general guide to integrate alerting and monitoring for Kasten 

# 3 use case 

We usually identify 3 common use case : 

- You're cluster is Openshift then you should leverage [the existing monitoring stack on openshift](./openshift.md)
- You already have a central monitoring stack that support Prometheus format then [you should leverage the kasten remote write support](https://www.veeam.com/kb4797) 
- You have nothing then you should enable the [prometheus community stack](./community.md)