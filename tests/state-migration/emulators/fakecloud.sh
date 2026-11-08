# SPDX-License-Identifier: Apache-2.0
# fakecloud. SM_FAKECLOUD_BIN is the fakecloud path (default: on PATH).
# FAKECLOUD_EC2_BACKEND=none keeps EC2 as metadata only, so no container
# runtime is needed and no instance boots.
emulator_start() {
  FAKECLOUD_EC2_BACKEND=none FAKECLOUD_CONTAINER_CLI=/nonexistent nohup \
    "${SM_FAKECLOUD_BIN:-fakecloud}" --addr "127.0.0.1:$SM_EMULATOR_PORT" \
    --region eu-west-1 >"$SM_EMULATOR_LOG" 2>&1 &
}

emulator_stop() {
  pkill -f "fakecloud --addr 127.0.0.1:$SM_EMULATOR_PORT"
}
