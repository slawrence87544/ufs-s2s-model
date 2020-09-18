#!/bin/bash
set -eux

echo "PID=$$"
SECONDS=0

trap '[ "$?" -eq 0 ] || write_fail_test' EXIT
trap 'echo "run_test.sh interrupted PID=$$"; cleanup' INT
trap 'echo "run_test.sh terminated PID=$$";  cleanup' TERM

cleanup() {
  [[ $ROCOTO = 'false' ]] && interrupt_job
  trap 0
  exit
}

write_fail_test() {
  if [[ ${UNIT_TEST} == true ]]; then
    echo ${TEST_NR} $TEST_NAME >> $PATHRT/fail_unit_test
  else
    echo "${TEST_NAME} ${TEST_NR} failed in run_test" >> $PATHRT/fail_test
  fi
  exit 1
}

if [[ $# != 5 ]]; then
  echo "Usage: $0 PATHRT RUNDIR_ROOT TEST_NAME TEST_NR COMPILE_NR"
  exit 1
fi

export PATHRT=$1
export RUNDIR_ROOT=$2
export TEST_NAME=$3
export TEST_NR=$4
export COMPILE_NR=$5

cd ${PATHRT}

[[ -e ${RUNDIR_ROOT}/run_test_${TEST_NR}.env ]] && source ${RUNDIR_ROOT}/run_test_${TEST_NR}.env
source default_vars.sh
source tests/$TEST_NAME
[[ -e ${RUNDIR_ROOT}/unit_test_${TEST_NR}.env ]] && source ${RUNDIR_ROOT}/unit_test_${TEST_NR}.env

# Save original CNTL_DIR name as INPUT_DIR for regression
# tests that try to copy input data from CNTL_DIR
export INPUT_DIR=${CNTL_DIR}
# Append RT_SUFFIX to RUNDIR, and BL_SUFFIX to CNTL_DIR
export RUNDIR=${RUNDIR_ROOT}/${TEST_NAME}${RT_SUFFIX}
export CNTL_DIR=${CNTL_DIR}${BL_SUFFIX}

export JBNME=$(basename $RUNDIR_ROOT)_${TEST_NR}

UNIT_TEST=${UNIT_TEST:-false}
if [[ ${UNIT_TEST} == false ]]; then
  REGRESSIONTEST_LOG=${LOG_DIR}/rt_${TEST_NR}_${TEST_NAME}${RT_SUFFIX}.log
else
  REGRESSIONTEST_LOG=${LOG_DIR}/ut_${TEST_NR}_${TEST_NAME}${RT_SUFFIX}.log
fi
export REGRESSIONTEST_LOG

echo "Test ${TEST_NR} ${TEST_NAME} ${TEST_DESCR}"

source rt_utils.sh
source atparse.bash
if [ $S2S == true ]; then
  source edit_inputs.sh
fi

mkdir -p ${RUNDIR}
cd $RUNDIR

###############################################################################
# Make configure and run files
###############################################################################

# FV3 executable:
cp ${PATHRT}/fcst_${COMPILE_NR}.exe                 fcst.exe

# modulefile for FV3 prerequisites:
cp ${PATHRT}/modules.fcst_${COMPILE_NR}             modules.fcst

# Get the shell file that loads the "module" command and purges modules:
cp ${PATHRT}/../NEMS/src/conf/module-setup.sh.inc  module-setup.sh
if [ $S2S != true ]; then
  cp ${PATHTR}/parm_weather/post_itag itag
  cp ${PATHTR}/parm_weather/postxconfig-NT.txt postxconfig-NT.txt
  cp ${PATHTR}/parm_weather/postxconfig-NT_FH00.txt postxconfig-NT_FH00.txt
  cp ${PATHTR}/parm_weather/params_grib2_tbl_new params_grib2_tbl_new
fi

SRCD="${PATHTR}"
RUND="${RUNDIR}"

# Set up the run directory
atparse < ${PATHRT}/fv3_conf/${FV3_RUN:-fv3_run.IN} > fv3_run
source ./fv3_run
if [ $S2S != true ]; then
  atparse < ${PATHTR}/parm_weather/${INPUT_NML:-input.nml.IN} > input.nml
  atparse < ${PATHTR}/parm_weather/${MODEL_CONFIGURE:-model_configure.IN} > model_configure
  atparse < ${PATHTR}/parm_weather/${NEMS_CONFIGURE:-nems.configure} > nems.configure
else
  atparse < ${PATHTR}/parm_s2s/${INPUT_NML:-input.nml.IN} > input.nml
  atparse < ${PATHTR}/parm_s2s/${MODEL_CONFIGURE:-model_configure.IN} > model_configure
  atparse < ${PATHTR}/parm_s2s/${NEMS_CONFIGURE:-nems.configure} > nems.configure
fi
if [ $S2S == true ]; then
  edit_ice_in < ${PATHTR}/parm_s2s/ice_in_template > ice_in
  edit_mom_input < ${PATHTR}/parm_s2s/${MOM_INPUT:-MOM_input_template_$OCNRES} > INPUT/MOM_input
  edit_diag_table < ${PATHTR}/parm_s2s/diag_table_template > diag_table
  edit_data_table < ${PATHTR}/parm_s2s/data_table_template > data_table

  cp ${PATHTR}/parm_s2s/fd_nems.yaml fd_nems.yaml
  cp ${PATHTR}/parm_s2s/pio_in pio_in
  cp ${PATHTR}/parm_s2s/med_modelio.nml med_modelio.nml
fi

if [[ "Q${INPUT_NEST02_NML:-}" != Q ]] ; then
    atparse < ${PATHTR}/parm_weather/${INPUT_NEST02_NML} > input_nest02.nml
fi

if [[ $SCHEDULER = 'pbs' ]]; then
  NODES=$(( TASKS / TPN ))
  if (( NODES * TPN < TASKS )); then
    NODES=$(( NODES + 1 ))
  fi
  atparse < $PATHRT/fv3_conf/fv3_qsub.IN > job_card
elif [[ $SCHEDULER = 'slurm' ]]; then
  NODES=$(( TASKS / TPN ))
  if (( NODES * TPN < TASKS )); then
    NODES=$(( NODES + 1 ))
  fi
  atparse < $PATHRT/fv3_conf/fv3_slurm.IN > job_card
elif [[ $SCHEDULER = 'lsf' ]]; then
  if (( TASKS < TPN )); then
    TPN=${TASKS}
  fi
  NODES=$(( TASKS / TPN ))
  if (( NODES * TPN < TASKS )); then
    NODES=$(( NODES + 1 ))
  fi
  atparse < $PATHRT/fv3_conf/fv3_bsub.IN > job_card
fi
if [ $S2S != true ]; then
atparse < ${PATHTR}/parm_weather/${NEMS_CONFIGURE:-nems.configure} > nems.configure
else
atparse < ${PATHTR}/parm_s2s/${NEMS_CONFIGURE:-nems.configure} > nems.configure
fi

################################################################################
# Submit test job
################################################################################

if [[ $SCHEDULER = 'none' ]]; then

  ulimit -s unlimited
  mpiexec -n ${TASKS} ./fv3.exe >out 2> >(tee err >&3)

else

  if [[ $ROCOTO = 'false' ]]; then
    submit_and_wait job_card
  else
    chmod u+x job_card
    ./job_card
  fi

fi

if [[ $S2S == true ]]; then
  check_results_s2s
else
  check_results_weather
fi

################################################################################
# End test
################################################################################

elapsed=$SECONDS
echo "Elapsed time $elapsed seconds. Test ${TEST_NAME}"
