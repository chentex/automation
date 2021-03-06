#!/bin/bash

zypper -n in -l -y ntp 

cat <<EOF > /etc/ntp.conf
server ntp1.suse.de
server ntp2.suse.de
server ntp3.suse.de
EOF

a=$(ip addr show eth0 | grep "inet\b" | awk '{print $2}' | cut -d/ -f1 | awk '{gsub ( "[.]","-" ) ; print "host-"$0 }')

cat <<EOF > /etc/hostname
$a
EOF

hostnamectl set-hostname $a

/usr/bin/systemctl stop SuSEfirewall2.service
/usr/bin/systemctl enable --now ntpd.service

zypper -n in -l -y salt-master salt-minion
systemctl enable salt-master.service
systemctl start salt-master.service

cat <<EOF > /etc/salt/minion.d/master.conf
master: $a
EOF

systemctl enable salt-minion.service
systemctl start salt-minion.service
sleep 2m && salt-key -q -y --accept-all
zypper -n in -l -y deepsea

cat <<EOF > /srv/pillar/ceph/stack/global.yml
stage_prep_master: default-no-update-no-reboot
stage_prep_minion: default-no-update-no-reboot
EOF

cat <<EOF > /srv/pillar/ceph/master_minion.sls
master_minion: $a.openstacklocal
EOF

cat <<EOF > /srv/pillar/ceph/deepsea_minions.sls
deepsea_minions: '*'    
EOF

salt '*' saltutil.sync_all

echo "Running deepsea stage 0"
deepsea stage run ceph.stage.0

echo "Running deepsea stage 1"
deepsea stage run ceph.stage.1

A=`ls /srv/pillar/ceph/proposals/role-mon/cluster | sed -r "s/.sls//g;s/$(hostname -f)//g"`
B=`ls /srv/pillar/ceph/proposals/profile-default/stack/default/ceph/minions | sed -r 's/.yml//g'`
C=`diff --side-by-side --suppress-common-lines <(echo "$A") <(echo "$B") | tr -d '< '`
policyf=/srv/pillar/ceph/proposals/policy.cfg

cat <<EOF > $policyf
## Cluster Assignment
cluster-ceph/cluster/*.sls

## Roles
# ADMIN
role-master/cluster/$(hostname -f).sls
EOF

for i in $(echo $C); do 
    echo role-admin/cluster/$i.sls >> $policyf
done

echo -e '\n# MON' >> $policyf

for i in $(echo $C); do 
    echo role-mon/cluster/$i.sls >> $policyf
done

echo -e '\n# MGR' >> $policyf

for i in $(echo $C); do 
    echo role-mgr/cluster/$i.sls >> $policyf
done

echo -e '\n# MDS' >> $policyf

for i in $(echo $C); do 
    echo role-mds/cluster/$i.sls >> $policyf
done

echo -e '\n# RGW\nrole-rgw/cluster/'$(hostname -f).sls >> $policyf

echo -e '
# COMMON
config/stack/default/global.yml 
config/stack/default/ceph/cluster.yml 

## Profiles
profile-default/cluster/*.sls 
profile-default/stack/default/ceph/minions/*.yml' >>  $policyf

echo "Running deepsea stage 2"
deepsea stage run ceph.stage.2

echo "Running deepsea stage 3"
deepsea stage run ceph.stage.3

echo "Running deepsea stage 4"
deepsea stage run ceph.stage.4

echo "creating k8s osd pool"
ceph osd pool create k8s 45 45

echo "output base64 ecoding of admin user"
ceph auth get-key client.admin | base64

echo "change update policy back to default"
cat <<EOF > /srv/pillar/ceph/stack/global.yml
stage_prep_master: default
stage_prep_minion: default
EOF

