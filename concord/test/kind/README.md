# README

When using these tests with KinD it is assumed that KinD is running and helm has been installed. You can use the provided `kind.sh` script to create a KinD cluster with the ingress required for the tests. The chart is installed in the `concord` namespace, and the tests are run assuming the use of the `concord` namespace.

Once the KinD cluster is running you can either use `test.sh` if you have manually installed the Concord chart, or you can use `test-with-provisioning.sh` if you want to delete everything in the `concord` namespace, provision everything again, and run the test Concord process.

Running the test you should see something like the following:

```
Waiting for the Concord server to start
http://localhost:80/api/v1/server/ping
...................
Submitting process...
dff92a8d-b1ac-4a86-8bf3-0187aab36e62

Waiting for the Concord process to finish
..........

Looking for completion message in process log...

SUCCESS!
```
