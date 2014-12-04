openstack-xenapi-testing-xva
============================

Scripts to generate an XVA that could be used for OpenStack testing. The
generated appliance is used in the official XenServer OpenStack CI as a domain
as the basis of devstack.

To be able to log in to the appliance, you should use xenstore to inject the
ssh key. Assuming you have `APPLIANCE_NAME` set, and `PUBKEY_PATH` pointing to
a public ssh key, execute the following scriptlet in dom0:

    VM=$(xe vm-list name-label="$APPLIANCE_NAME" --minimal)
    DOMID=$(xe vm-param-get param-name=dom-id uuid=$VM)
    xenstore-write \
        /local/domain/$DOMID/authorized_keys/$DOMZERO_USER \
        "$(cat $PUBKEY_PATH)"
    xenstore-chmod \
        -u /local/domain/$DOMID/authorized_keys/$DOMZERO_USER \
        r$DOMID

As a cron job is watching writing the contents of the xenstore to the root
user's authorized_keys file, remember to disable the cron job.
