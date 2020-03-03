#!/bin/bash
set -eux

# Prepare env vars
ENGINE=${ENGINE:="podman"}
OS=${OS:="centos"}
OS_VERSION=${OS_VERSION:="7"}
PYTHON_VERSION=${PYTHON_VERSION:="2"}
ACTION=${ACTION:="test"}
IMAGE="$OS:$OS_VERSION"
engine_mounts="-v $PWD:$PWD:z"
for dir in ${EXTRA_MOUNT:-}; do
  engine_mounts="${engine_mounts} -v $dir:$dir:z"
done

# Pull fedora images from registry.fedoraproject.org
if [[ $OS == "fedora" ]]; then
  IMAGE="registry.fedoraproject.org/$IMAGE"
fi


CONTAINER_NAME="osbs-client-$OS-$OS_VERSION-py$PYTHON_VERSION"
RUN="$ENGINE exec -ti $CONTAINER_NAME"
if [[ $OS == "fedora" ]]; then
  PIP_PKG="python$PYTHON_VERSION-pip"
  PIP="pip$PYTHON_VERSION"
  PKG="dnf"
  PKG_EXTRA="dnf-plugins-core"
  BUILDDEP="dnf builddep"
  PYTHON="python$PYTHON_VERSION"
else
  PIP_PKG="python-pip"
  PIP="pip"
  PKG="yum"
  PKG_EXTRA="yum-utils epel-release"
  BUILDDEP="yum-builddep"
  PYTHON="python"
fi
# Create or resurrect container if needed
if [[ $($ENGINE ps -qa -f name=$CONTAINER_NAME | wc -l) -eq 0 ]]; then
  $ENGINE run --name $CONTAINER_NAME -d $engine_mounts -w $PWD -ti $IMAGE sleep infinity
elif [[ $($ENGINE ps -q -f name=$CONTAINER_NAME | wc -l) -eq 0 ]]; then
  echo found stopped existing container, restarting. volume mounts cannot be updated.
  $ENGINE container start $CONTAINER_NAME
fi

# Install dependencies
$RUN $PKG install -y $PKG_EXTRA
[[ ${PYTHON_VERSION} == '3' ]] && WITH_PY3=1 || WITH_PY3=0
$RUN $BUILDDEP --define "with_python3 ${WITH_PY3}" -y osbs-client.spec
if [[ $OS != "fedora" ]]; then
  # Install dependecies for test, as check is disabled for rhel
  $RUN yum install -y python-flexmock python-six python-dockerfile-parse python-requests python-requests-kerberos
fi

# Install package
$RUN $PKG install -y $PIP_PKG
if [[ $PYTHON_VERSION == 3 ]]; then
  # https://fedoraproject.org/wiki/Changes/Making_sudo_pip_safe
  $RUN mkdir -p /usr/local/lib/python3.6/site-packages/
fi

# CentOS needs to have setuptools updates to use wildcards in requirements.txt and to make pytest-cov work
if [[ $OS != "fedora" ]]; then
  $RUN $PIP install -U setuptools

  # Watch out for https://github.com/pypa/setuptools/issues/937
  $RUN curl -O https://bootstrap.pypa.io/2.6/get-pip.py
  $RUN $PYTHON get-pip.py
fi
$RUN $PYTHON setup.py install

# Install packages for tests
$RUN $PIP install -r tests/requirements.txt
if [[ $PYTHON_VERSION -gt 2 ]]; then $RUN $PIP install -r requirements-py3.txt; fi

case ${ACTION} in
"test")
  TEST_CMD="py.test --cov osbs --cov-report html tests"
  ;;
"pylint")
  # This can run only at fedora because pylint is not packaged in centos
  # use distro pylint to not get too new pylint version
  $RUN $PKG install -y "${PYTHON}-pylint"
  PACKAGES='osbs tests'
  TEST_CMD="${PYTHON} -m pylint ${PACKAGES}"
  ;;
"bandit")
  $RUN $PIP install bandit
  TEST_CMD="bandit-baseline -r osbs -ll -ii"
  ;;
*)
  echo "Unknown action: ${ACTION}"
  exit 2
  ;;
esac

# Run tests
$RUN  ${TEST_CMD} "$@"

echo "To run tests again:"
echo "$RUN ${TEST_CMD}"
