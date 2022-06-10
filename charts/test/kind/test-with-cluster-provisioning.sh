#!/bin/bash

kind delete cluster
./kind.sh
./chart-install.sh
./test.sh
