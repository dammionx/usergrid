#!/bin/bash

# 
#  Licensed to the Apache Software Foundation (ASF) under one or more
#   contributor license agreements.  The ASF licenses this file to You
#  under the Apache License, Version 2.0 (the "License"); you may not
#  use this file except in compliance with the License.
#  You may obtain a copy of the License at
# 
#      http://www.apache.org/licenses/LICENSE-2.0
# 
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.  For additional information regarding
#  copyright in this work, please see the NOTICE file in the top level
#  directory of this distribution.
#



echo "${HOSTNAME}" > /etc/hostname
echo "127.0.0.1 ${HOSTNAME}" >> /etc/hosts
hostname `cat /etc/hostname`

echo "US/Eastern" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

PKGS="openjdk-7-jdk tomcat7 s3cmd ntp unzip groovy"
apt-get update
apt-get -y --force-yes install ${PKGS}
/etc/init.d/tomcat7 stop

# Install AWS Java SDK and get it into the Groovy classpath
curl http://sdk-for-java.amazonwebservices.com/latest/aws-java-sdk.zip > /tmp/aws-sdk-java.zip
cd /usr/share/
unzip /tmp/aws-sdk-java.zip 
mkdir -p /home/ubuntu/.groovy/lib
cp /usr/share/aws-java-sdk-*/third-party/*/*.jar /home/ubuntu/.groovy/lib
cp /usr/share/aws-java-sdk-*/lib/* /home/ubuntu/.groovy/lib 
ln -s /home/ubuntu/.groovy /root/.groovy

# Build environment for Groovy scripts
. /etc/profile.d/aws-credentials.sh
. /etc/profile.d/usergrid-env.sh


# tag last so we can see in the console so that we know what's running
cd /usr/share/usergrid/scripts
groovy tag_instance.groovy -BUILD-IN-PROGRESS



chmod +x /usr/share/usergrid/update.sh

cd /usr/share/usergrid/init_instance
./install_oraclejdk.sh 

cd /usr/share/usergrid/init_instance
./install_yourkit.sh

# set Tomcat memory and threads based on instance type
# use about 70% of RAM for heap
export NOFILE=150000
export TOMCAT_CONNECTIONS=10000
export ACCEPT_COUNT=1600
export NR_OPEN=1048576
export FILE_MAX=761773

case `(curl http://169.254.169.254/latest/meta-data/instance-type)` in
'm1.small' )
    # total of 1.7g
    export TOMCAT_RAM=1190m
    export TOMCAT_THREADS=300
;;
'm1.medium' )
    # total of 3.75g
    export TOMCAT_RAM=2625m
    export TOMCAT_THREADS=500
;;
'm1.large' )
    # total of 7.5g
    export TOMCAT_RAM=5250m
    export TOMCAT_THREADS=1000
;;
'm1.xlarge' )
    # total of 15g
    export TOMCAT_RAM=10500m
    export TOMCAT_THREADS=2000
;;
'm3.large' )
    # total of 7.5g
    export TOMCAT_RAM=5250m
    export TOMCAT_THREADS=1600
;;
'm3.xlarge' )
    # total of 15g
    export TOMCAT_RAM=10500m
    export TOMCAT_THREADS=3300
;;
'c3.xlarge' )
    # total of 7.5g
    export TOMCAT_RAM=4096m
    export TOMCAT_THREADS=7000
;;
'c3.2xlarge' )
    # total of 15g
    export TOMCAT_RAM=10500m
    export TOMCAT_THREADS=2000
;;
'c3.4xlarge' )
    # total of 30g
    export TOMCAT_RAM=21000m
    export TOMCAT_THREADS=4000
esac


sed -i.bak "s/Xmx128m/Xmx${TOMCAT_RAM} -Xms${TOMCAT_RAM} -Dlog4j\.configuration=file:\/usr\/share\/usergrid\/lib\/log4j\.properties/g" /etc/default/tomcat7
sed -i.bak "s/<Connector/<Connector maxThreads=\"${TOMCAT_THREADS}\" acceptCount=\"${ACCEPT_COUNT}\" maxConnections=\"${TOMCAT_CONNECTIONS}\"/g" /var/lib/tomcat7/conf/server.xml


#Append our java opts for secret key
echo "JAVA_OPTS=\"\${JAVA_OPTS} -DAWS_SECRET_KEY=${AWS_SECRET_KEY} -DAWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY}\"" >> /etc/default/tomcat7

ulimit -n $NOFILE

# set file limits
sed -i.bak "s/# \/etc\/init\.d\/tomcat7 -- startup script for the Tomcat 6 servlet engine/ulimit -n ${NOFILE}/" /etc/init.d/tomcat7


cat >>  /etc/security/limits.conf  << EOF
* - nofile ${NOFILE}
root - nofile ${NOFILE}
EOF



echo "${NR_OPEN}" | sudo tee > /proc/sys/fs/nr_open
echo "${FILE_MAX}" | sudo tee > /proc/sys/fs/file-max


cat >> /etc/pam.d/su << EOF
session    required   pam_limits.so
EOF



# increase system IP port limits (do we really need this for Tomcat?)
sysctl -w net.ipv4.ip_local_port_range="1024 65535"
cat >> /etc/sysctl.conf << EOF
####
# Set by usergrid rest setup
####
net.ipv4.ip_local_port_range = 1024 65535

# Controls the default maxmimum size of a mesage queue
kernel.msgmnb = 65536

# Controls the maximum size of a message, in bytes
kernel.msgmax = 65536

# Controls the maximum shared segment size, in bytes
kernel.shmmax = 68719476736

# Controls the maximum number of shared memory segments, in pages
kernel.shmall = 4294967296

######
# End usergrid setup
######
EOF

# wait for enough Cassandra nodes then delpoy and configure Usergrid 
cd /usr/share/usergrid/scripts
groovy wait_for_instances.groovy cassandra ${CASSANDRA_NUM_SERVERS}
groovy wait_for_instances.groovy elasticsearch ${ES_NUM_SERVERS}
groovy wait_for_instances.groovy graphite ${GRAPHITE_NUM_SERVERS}

# link WAR and Portal into Tomcat's webapps dir
rm -rf /var/lib/tomcat7/webapps/*
ln -s /usr/share/usergrid/webapps/ROOT.war /var/lib/tomcat7/webapps/ROOT.war
ln -s /usr/share/usergrid/webapps/portal /var/lib/tomcat7/webapps/portal
chown -R tomcat7 /usr/share/usergrid/webapps
chown -R tomcat7 /var/lib/tomcat7/webapps

# configure usergrid
mkdir -p /usr/share/tomcat7/lib 
groovy configure_usergrid.groovy > /usr/share/tomcat7/lib/usergrid-deployment.properties 
groovy configure_portal_new.groovy >> /var/lib/tomcat7/webapps/portal/config.js



#Install postfix so that we can send mail
echo "postfix postfix/mailname string your.hostname.com" | debconf-set-selections
echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections
apt-get install -y postfix


# Go
sh /etc/init.d/tomcat7 start

# tag last so we can see in the console that the script ran to completion
cd /usr/share/usergrid/scripts
groovy tag_instance.groovy
