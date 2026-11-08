# SPDX-License-Identifier: Apache-2.0
# moto server. SM_MOTO_BIN is the moto_server path (default: on PATH).
# Needs the AWS managed policies, which the aws-cluster roles attach.
emulator_start() {
  MOTO_IAM_LOAD_MANAGED_POLICIES=true nohup "${SM_MOTO_BIN:-moto_server}" \
    -H 127.0.0.1 -p "$SM_EMULATOR_PORT" >"$SM_EMULATOR_LOG" 2>&1 &
}

emulator_stop() {
  pkill -f "moto_server -H 127.0.0.1 -p $SM_EMULATOR_PORT"
}
