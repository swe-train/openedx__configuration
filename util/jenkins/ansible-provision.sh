#!/usr/bin/env bash

# Ansible provisioning wrapper script that
# assumes the following parameters set
# as environment variables
#
# - github_username
# - server_type
# - instance_type
# - region
# - aws_account
# - keypair
# - ami
# - root_ebs_size
# - security_group
# - dns_zone
# - dns_name
# - environment
# - name_tag
set -x

# Seeing the environment is fine, spewing secrets to the log isn't ok
env | grep -v AWS | grep -v ARN

export PYTHONUNBUFFERED=1
export BOTO_CONFIG=/var/lib/jenkins/${aws_account}.boto

# docker on OS-X includes your Mac's home directory in the socket path
# that SSH/Ansible uses for the control socket, pushing you over
# the 108 character limit.
if [ -f /.dockerenv ]; then
    export ANSIBLE_SSH_CONTROL_PATH=/tmp/%%C
fi

run_ansible() {
  if [[ "$VERBOSE" == "true" ]]; then
    verbose_arg='-vvv'
  else
    verbose_arg=''
  fi

  ansible-playbook $verbose_arg $@
  ret=$?
  if [[ $ret -ne 0 ]]; then
    exit $ret
  fi
}

# This DATE_TIME will be used as instance launch time tag
if [[ ! -n ${sandbox_life//[0-9]/} ]]  && [[ ${sandbox_life} -le 30 ]]; then
    TERMINATION_DATE_TIME=`date +"%m-%d-%Y %T" --date "${sandbox_life=7} days"`
else
   echo "Please enter the valid value for the sandbox_life(between 1 to 30)"
   exit 1
fi


if [[ -z $BUILD_USER ]]; then
    BUILD_USER=jenkins
fi

if [[ -z $BUILD_USER_ID ]]; then
    BUILD_USER_ID=edx-sandbox
fi


if [[ -z $WORKSPACE ]]; then
    dir=$(dirname $0)
    source "$dir/ascii-convert.sh"
else
    source "$WORKSPACE/configuration/util/jenkins/ascii-convert.sh"
fi

if [[ -z $static_url_base ]]; then
  static_url_base="/static"
fi

if [[ -z $github_username  ]]; then
  github_username=$BUILD_USER_ID
fi

# Having access keys OR a boto config allows sandboxes to be built.
if [[ ( -z $AWS_ACCESS_KEY_ID || -z $AWS_SECRET_ACCESS_KEY ) && (! -f $BOTO_CONFIG) ]]; then
  echo "AWS credentials not found for $aws_account"
  exit 1
fi

extra_vars_file="/var/tmp/extra-vars-$$.yml"
sandbox_secure_vars_file="${WORKSPACE}/configuration-secure/ansible/vars/developer-sandbox.yml"
sandbox_internal_vars_file="${WORKSPACE}/configuration-internal/ansible/vars/developer-sandbox.yml"
extra_var_arg="-e@${extra_vars_file}"

if [[ $edx_internal == "true" ]]; then
    # if this is a an edx server include
    # the secret var file
    extra_var_arg="-e@${sandbox_internal_vars_file} -e@${sandbox_secure_vars_file} -e@${extra_vars_file}"
fi

if [[ -z $region ]]; then
  region="us-east-1"
fi

# edX has reservations for sandboxes in this zone, don't change without updating reservations.
if [[ -z $zone ]]; then
  zone="us-east-1c"
fi

if [[ -z $vpc_subnet_id ]]; then
  vpc_subnet_id="subnet-cd867aba"
fi

if [[ -z $elb ]]; then
  elb="false"
fi

if [[ -z $dns_name ]]; then
  dns_name=${github_username}
fi

if [[ -z $name_tag ]]; then
  name_tag=${github_username}-${environment}
fi

if [[ -z $sandbox_platform_name ]]; then
    sandbox_platform_name=$dns_name
fi

if [[ -z $ami ]]; then
  if [[ $server_type == "full_edx_installation" ]]; then
    ami="ami-dd9d81a6"
  elif [[ $server_type == "ubuntu_16.04" || $server_type == "full_edx_installation_from_scratch" ]]; then
    ami="ami-1d4e7a66"
  fi
fi

if [[ -z $instance_type ]]; then
  instance_type="t2.large"
fi

if [[ -z $instance_initiated_shutdown_behavior ]]; then
  instance_initiated_shutdown_behavior="terminate"
fi

if [[ -z $enable_newrelic ]]; then
  enable_newrelic="false"
fi

if [[ -z $enable_datadog ]]; then
  enable_datadog="false"
fi

if [[ -z $performance_course ]]; then
  performance_course="false"
fi

if [[ -z $demo_test_course ]]; then
  demo_test_course="false"
fi

if [[ -z $edx_demo_course ]]; then
  edx_demo_course="false"
fi

if [[ -z $enable_automatic_auth_for_testing ]]; then
  enable_automatic_auth_for_testing="false"
fi

if [[ -z $enable_client_profiling ]]; then
  enable_client_profiling="false"
fi

# Lowercase the dns name to deal with an ansible bug
dns_name="${dns_name,,}"

deploy_host="${dns_name}.${dns_zone}"
ssh-keygen -f "/var/lib/jenkins/.ssh/known_hosts" -R "$deploy_host"

cd playbooks/edx-east

cat << EOF > $extra_vars_file
edx_platform_version: $edxapp_version
forum_version: $forum_version
notifier_version: $notifier_version
xqueue_version: $xqueue_version
xserver_version: $xserver_version
certs_version: $certs_version
configuration_version: $configuration_version
demo_version: $demo_version

edx_ansible_source_repo: ${configuration_source_repo}
edx_platform_repo: ${edx_platform_repo}

EDXAPP_PLATFORM_NAME: $sandbox_platform_name

EDXAPP_STATIC_URL_BASE: $static_url_base
EDXAPP_LMS_NGINX_PORT: 80
EDXAPP_CMS_NGINX_PORT: 80

ECOMMERCE_NGINX_PORT: 80
ECOMMERCE_SSL_NGINX_PORT: 443
ECOMMERCE_VERSION: $ecommerce_version

CREDENTIALS_NGINX_PORT: 80
CREDENTIALS_SSL_NGINX_PORT: 443
CREDENTIALS_VERSION: $credentials_version

DISCOVERY_NGINX_PORT: 80
DISCOVERY_SSL_NGINX_PORT: 443
DISCOVERY_VERSION: $discovery_version
NGINX_SET_X_FORWARDED_HEADERS: True
NGINX_REDIRECT_TO_HTTPS: True
EDX_ANSIBLE_DUMP_VARS: true
migrate_db: "yes"
rabbitmq_ip: "127.0.0.1"
rabbitmq_refresh: True
COMMON_HOSTNAME: $dns_name
COMMON_DEPLOYMENT: edx
COMMON_ENVIRONMENT: sandbox

nginx_default_sites:
  - lms

# User provided extra vars
$extra_vars
EOF

if [[ $basic_auth == "true" ]]; then
    # vars specific to provisioning added to $extra-vars
    cat << EOF_AUTH >> $extra_vars_file
COMMON_ENABLE_BASIC_AUTH: True
COMMON_HTPASSWD_USER: $auth_user
COMMON_HTPASSWD_PASS: $auth_pass
XQUEUE_BASIC_AUTH_USER: $auth_user
XQUEUE_BASIC_AUTH_PASSWORD: $auth_pass
EOF_AUTH

else
    cat << EOF_AUTH >> $extra_vars_file
COMMON_ENABLE_BASIC_AUTH: False
EOF_AUTH

fi

if [[ -n $nginx_users ]]; then
   cat << EOF_AUTH >> $extra_vars_file
NGINX_USERS: $nginx_users
EOF_AUTH
fi

if [[ $enable_client_profiling == "true" ]]; then
    cat << EOF_PROFILING >> $extra_vars_file
EDXAPP_SESSION_SAVE_EVERY_REQUEST: True
EOF_PROFILING
fi

if [[ $edx_internal == "true" ]]; then
    # if this isn't a public server add the github
    # user and set edx_internal to True so that
    # xserver is installed
    cat << EOF >> $extra_vars_file
EDXAPP_PREVIEW_LMS_BASE: preview-${deploy_host}
EDXAPP_LMS_BASE: ${deploy_host}
EDXAPP_CMS_BASE: studio-${deploy_host}
EDXAPP_SITE_NAME: ${deploy_host}
CERTS_DOWNLOAD_URL: "http://${deploy_host}:18090"
CERTS_VERIFY_URL: "http://${deploy_host}:18090"
edx_internal: True
COMMON_USER_INFO:
  - name: ${github_username}
    github: true
    type: admin
USER_CMD_PROMPT: '[$name_tag] '
COMMON_ENABLE_NEWRELIC_APP: $enable_newrelic
COMMON_ENABLE_DATADOG: $enable_datadog
COMMON_OAUTH_BASE_URL: "https://${deploy_host}"
FORUM_NEW_RELIC_ENABLE: $enable_newrelic
ENABLE_PERFORMANCE_COURSE: $performance_course
ENABLE_DEMO_TEST_COURSE: $demo_test_course
ENABLE_EDX_DEMO_COURSE: $edx_demo_course
EDXAPP_ENABLE_AUTO_AUTH: $enable_automatic_auth_for_testing
EDXAPP_NEWRELIC_LMS_APPNAME: sandbox-${dns_name}-edxapp-lms
EDXAPP_NEWRELIC_CMS_APPNAME: sandbox-${dns_name}-edxapp-cms
EDXAPP_NEWRELIC_WORKERS_APPNAME: sandbox-${dns_name}-edxapp-workers
XQUEUE_NEWRELIC_APPNAME: sandbox-${dns_name}-xqueue
FORUM_NEW_RELIC_APP_NAME: sandbox-${dns_name}-forums
SANDBOX_USERNAME: $github_username
EDXAPP_ECOMMERCE_PUBLIC_URL_ROOT: "https://ecommerce-${deploy_host}"
EDXAPP_ECOMMERCE_API_URL: "https://ecommerce-${deploy_host}/api/v2"
EDXAPP_COURSE_CATALOG_API_URL: "https://catalog-${deploy_host}/api/v1"

# NOTE: This is the same as DISCOVERY_URL_ROOT below
ECOMMERCE_DISCOVERY_SERVICE_URL: "https://discovery-${deploy_host}"
ECOMMERCE_ECOMMERCE_URL_ROOT: "https://ecommerce-${deploy_host}"
ECOMMERCE_LMS_URL_ROOT: "https://${deploy_host}"
ECOMMERCE_SOCIAL_AUTH_REDIRECT_IS_HTTPS: true
ecommerce_create_demo_data: true

CREDENTIALS_LMS_URL_ROOT: "https://${deploy_host}"
CREDENTIALS_DOMAIN: "credentials-${deploy_host}"
CREDENTIALS_URL_ROOT: "https://{{ CREDENTIALS_DOMAIN }}"
CREDENTIALS_SOCIAL_AUTH_REDIRECT_IS_HTTPS: true
COURSE_DISCOVERY_ECOMMERCE_API_URL: "https://ecommerce-${deploy_host}/api/v2"

DISCOVERY_URL_ROOT: "https://discovery-${deploy_host}"
DISCOVERY_SOCIAL_AUTH_REDIRECT_IS_HTTPS: true

EOF
fi


if [[ $recreate == "true" ]]; then
    # vars specific to provisioning added to $extra-vars
    cat << EOF >> $extra_vars_file
dns_name: $dns_name
keypair: $keypair
instance_type: $instance_type
security_group: $security_group
ami: $ami
region: $region
zone: $zone
instance_initiated_shutdown_behavior: $instance_initiated_shutdown_behavior
instance_tags:
    environment: $environment
    github_username: $github_username
    Name: $name_tag
    source: jenkins
    owner: $BUILD_USER
    instance_termination_time: $TERMINATION_DATE_TIME
    datadog: monitored
root_ebs_size: $root_ebs_size
name_tag: $name_tag
dns_zone: $dns_zone
elb: $elb
EOF


    if [[ $server_type == "full_edx_installation" ]]; then
        extra_var_arg+=' -e instance_userdata="" -e launch_wait_time=0 -e elb_pre_post=false'
    fi
    # run the tasks to launch an ec2 instance from AMI
    cat $extra_vars_file
    run_ansible edx_provision.yml -i inventory.ini $extra_var_arg --user ubuntu

    if [[ $server_type == "full_edx_installation" ]]; then
        # additional tasks that need to be run if the
        # entire edx stack is brought up from an AMI
        run_ansible rabbitmq.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
        run_ansible restart_supervisor.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
    fi
fi

declare -A deploy
roles="edxapp forum ecommerce credentials discovery notifier xqueue xserver certs demo testcourses"

for role in $roles; do
    deploy[$role]=${!role}
done

# If reconfigure was selected or if starting from an ubuntu 16.04 AMI
# run non-deploy tasks for all roles
if [[ $reconfigure == "true" || $server_type == "full_edx_installation_from_scratch" ]]; then
    cat $extra_vars_file
    run_ansible edx_continuous_integration.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
fi

if [[ $reconfigure != "true" && $server_type == "full_edx_installation" ]]; then
    # Run deploy tasks for the roles selected
    for i in $roles; do
        if [[ ${deploy[$i]} == "true" ]]; then
            cat $extra_vars_file
            run_ansible ${i}.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
            if [[ ${i} == "edxapp" ]]; then
                run_ansible worker.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
            fi
        fi
    done
fi

# deploy the edx_ansible role
run_ansible edx_ansible.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
cat $sandbox_secure_vars_file $sandbox_internal_vars_file $extra_vars_file | grep -v -E "_version|migrate_db" > ${extra_vars_file}_clean
ansible -c ssh -i "${deploy_host}," $deploy_host -m copy -a "src=${extra_vars_file}_clean dest=/edx/app/edx_ansible/server-vars.yml" -u ubuntu -b
ret=$?
if [[ $ret -ne 0 ]]; then
  exit $ret
fi

if [[ $run_oauth == "true" ]]; then
    # Setup the OAuth2 clients
    run_ansible oauth_client_setup.yml -i "${deploy_host}," $extra_var_arg --user ubuntu
fi

# set the hostname
run_ansible set_hostname.yml -i "${deploy_host}," -e hostname_fqdn=${deploy_host} --user ubuntu

rm -f "$extra_vars_file"
rm -f ${extra_vars_file}_clean
