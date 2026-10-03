#!/bin/bash
# CUBRID runtime environment for the experiments (local build in /home/user/cubrid/install)
export CUBRID=${CUBRID:-/home/user/cubrid/install}
export CUBRID_DATABASES=${CUBRID_DATABASES:-$CUBRID/databases}
export PATH=$CUBRID/bin:$PATH
export LD_LIBRARY_PATH=$CUBRID/lib:${LD_LIBRARY_PATH:-}
export DB=${DB:-testdb}
export WORK=${WORK:-/home/user/cubrid/work}
mkdir -p "$WORK"
