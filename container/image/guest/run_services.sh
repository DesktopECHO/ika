#!/usr/bin/env bash

systemctl start nginx
systemctl start cuttlefish-host-resources
systemctl start cuttlefish-operator
systemctl start cuttlefish-host_orchestrator

# To keep it running
tail -f /dev/null
