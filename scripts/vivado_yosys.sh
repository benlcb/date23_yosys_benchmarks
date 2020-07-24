#!/bin/bash

# Adapted from https://github.com/YosysHQ/yosys-bench/blob/cmp/scripts/vivado_min_period.sh
# Adapted from https://github.com/cliffordwolf/picorv32/blob/d046cbfa4986acb50ef6b6e5ff58e9cab543980b/scripts/vivado/tabtest.sh

# "exit immediately if a command exits with a non-zero status"
#set -e

input=
dev="xc7a200"
grade=1
speed=5000  # picoseconds
synth="yosys" # yosys | yosys-abc9 | vivado
clean=false

while [ "$1" != "" ]; do
  case $1 in
    -i | --input )          shift
                            input="$1"
                            ;;
    -d | --device )         shift
                            dev="$1"
                            ;;
    -g | --grade )          shift
                            grade="$1"
                            ;;
    -s | --speed )          shift
                            speed="$1"
                            ;;
    -m | --synth_method )   shift
                            synth="$1"
                            ;;
    -c | --clean )          shift
                            clean=true
                            ;;
    * )                     echo "computer says no: ${1}"
                            exit 1
  esac
  shift
done

if ! [ -f "${input}" ]; then
  echo "Input file not found: ${input}"
  exit 1
fi
path=$(readlink -f "${input}")
echo "Starting '${synth}' on '${path}'"
ip="$(basename -- ${path})"
ip=${ip%.gz}
ip=${ip%.*}

# NOTE: You can export a spreadsheet of supported devices from Vivado's Project
# Settings dialog.
case "${dev}" in
  xc7a) xl_device="xc7a100tcsg324-${grade}" ;;
  xc7a200) xl_device="xc7a200tffv1156-${grade}" ;;
  xc7k) xl_device="" ;;
  xc7v) xl_device="" ;;
  xcku) xl_device="xcku035-ffva1156-${grade}-e" ;;
  xcvu2104) xl_device="xcvu35p-fsvh2104-${grade}-e" ;; # needs license
  xckup) xl_device="" ;;
  xcvu2892) xl_device="xcvu35p-fsvh2892-${grade}-e" ;; # needs license
esac

YOSYS=${YOSYS:-/home/arya/src/yosys/yosys}
VIVADO=${VIVADO:-/opt/Xilinx/Vivado/2020.1/bin/vivado}

# echo "speed=${speed}"
# echo "dev=${dev}"
# echo "grade=${grade}"
# echo "ip=${ip}"
# echo "path=${path}"
# echo "clean=${clean}"
# echo "xl_device=${xl_device}"
# echo "YOSYS=${YOSYS}"
# echo "VIVADO=${VIVADO}"

test_name="tab_${synth}_${ip}_${dev}_${grade}"

if ${clean}; then
  rm -rf "${test_name}"
fi
mkdir -p ${test_name}
cd ${test_name}
#rm -f ${ip}.edif

synth_case() {
  run_name="test_${1}"

  if [ -f test_${1}.txt ]; then
    echo "${test_name} reusing cached test_${1}."
    return
  fi

  cat > test_${1}.tcl <<EOT
set_param general.maxThreads 1
set_property IS_ENABLED 0 [get_drc_checks {PDRC-43}]
EOT

  pwd=${PWD}
  if [ "${synth}" = "vivado" ]; then
    cat >> test_${1}.tcl <<EOT
cd $(dirname ${path})
EOT
    if [ "${path##*.}" == "gz" ]; then
      gunzip -f -k ${path}
    fi
    cat >> test_${1}.tcl <<EOT
if {[file exists "$(dirname ${path})/${ip}_vivado.tcl"] == 1} {
  source ${ip}_vivado.tcl
} else {
  read_verilog $(basename ${path%.gz})
  #read_verilog ${path}
}
if {[file exists "$(dirname ${path})/${ip}.top"] == 1} {
  set fp [open $(dirname ${path})/${ip}.top]
  set_property TOP [string trim [read \$fp]] [current_fileset]
} else {
  set_property TOP [lindex [find_top] 0] [current_fileset]
}
cd ${pwd}
read_xdc test_${1}.xdc
synth_design -part ${xl_device} -mode out_of_context ${SYNTH_DESIGN_OPTS}
opt_design -directive Explore
EOT

  else
    edif="${ip}.edif"
    synth_with_abc9=
    if [ "${synth}" = "yosys-abc9" ]; then
      synth_with_abc9="-abc9"
    fi
    if [ -f "${edif}" ]; then
      echo "${test_name} reusing cached ${edif}"
    else
      if [ -f "$(dirname ${path})/${ip}.ys" ]; then
        echo "script ${ip}.ys" > ${ip}.ys
      elif [ ${path:-5} == ".vhdl" ]; then
          echo "read -vhdl $(basename ${path})" > ${ip}.ys
      else
          #echo "read_verilog $(basename ${path})" > ${ip}.ys
          echo "read_verilog ${path}" > ${ip}.ys
      fi

      # If the top is specified in a .top file, specify that to Yosys so that
      # the hierarchy can be trimmed of other garbage (I mean, unnecessary
      # artifacts).
      top_file="$(dirname ${path})/${ip}.top"
      if [ -f "${top_file}" ]; then
        echo "hierarchy -check -top $(<${top_file})" >> ${ip}.ys
      fi

      cat >> ${ip}.ys <<EOT
synth_xilinx -dff -flatten ${synth_with_abc9} -edif ${edif}
write_verilog -noexpr -norename ${pwd}/${ip}_syn.v
EOT

      echo "${test_name} running ${ip}.ys..."
      #pushd $(dirname ${path}) > /dev/null
      if ! ${YOSYS} -l ${pwd}/yosys.log ${pwd}/${ip}.ys > /dev/null 2>&1; then
        cat ${pwd}/yosys.log
        exit 1
      fi
      #popd > /dev/null
      mv yosys.log yosys.txt
    fi

    cat >> test_${1}.tcl <<EOT
read_edif ${edif}
read_xdc test_${1}.xdc
link_design -part ${xl_device} -mode out_of_context -top ${ip}
EOT
  fi

  speed_ns=$(printf %.2f "$((speed))e-3")
  cat > test_${1}.xdc <<EOT
create_clock -period ${speed_ns} [get_ports -nocase -regexp .*cl(oc)?k.*]
EOT
  cat >> test_${1}.tcl <<EOT
report_design_analysis
place_design -directive Explore
route_design -directive Explore
report_utilization
report_timing -no_report_unconstrained
report_design_analysis
EOT

  echo "${test_name} running test_${1}..."
  if ! $VIVADO -nojournal -log test_${1}.log -mode batch -source test_${1}.tcl > /dev/null 2>&1; then
    cat test_${1}.log
    exit 1
  fi
  mv test_${1}.log test_${1}.txt
}

remaining_iterations=3
speed_upper_bound=${speed}
speed_lower_bound=0
met_timing=false

# TODO(aryap): Might not want this to exit the script if a run is broken, since
# previous runs might have had results we want to keep (i.e. dump to
# 'best_speed.txt').
check_timing() {
  timing_results_file="test_${1}.txt"
  if [ ! -f "${timing_results_file}" ]; then
    echo "${test_name} broken run; could not find timing results: ${timing_results_file}"
    exit 3
  fi

  if grep -qE '^Slack \(MET\)' "${timing_results_file}"; then 
    met_timing=true
  elif grep -qE '^Slack \(VIOLATED\)' "${timing_results_file}"; then 
    met_timing=false
  else
    echo "${test_name} broken run, could not find 'Slack: (VIOLATED|MET)' in results file: ${timing_results_file}"
    exit 4
  fi
}

last_speed=
while [ ${remaining_iterations} -gt 0 ]; do
  echo "${test_name} Commencing iteration @ speed: ${speed}"
  synth_case "${speed}"

  check_timing "${speed}"

  if [ "${met_timing}" = true ]; then
    speed_upper_bound=${speed}
    best_speed=${speed}
    echo "${test_name} MET      timing @ speed: ${speed}"
  elif [ "${met_timing}" = false ]; then
    speed_lower_bound=${speed}
    echo "${test_name} VIOLATED timing @ speed: ${speed}"
  fi
  last_speed=${speed}
  speed=$(((speed_upper_bound + speed_lower_bound) / 2))
  remaining_iterations=$((remaining_iterations - 1))

  # If we're trying to run the same speed twice in a row, we should stop.
  if [ -n "${last_speed}" -a "${last_speed}" = "${speed}" ]; then
    echo "${test_name} search not making progress since last speed: ${speed}"
    break
  fi
done

if [ -n "${best_speed}" ]; then
  echo "${best_speed}" > best_speed.txt
fi
