#!/bin/bash
set -eux

hg clone http://hg.uk.xensource.com/openstack/infrastructure.hg/ infra

cd infra/osci

./ssh.sh prod_ci "rm -rf xva_images && mkdir xva_images" < /dev/null
./scp.sh prod_ci/ ~/*.xva xva_images/image.xva < /dev/null
