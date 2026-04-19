#!/system/bin/sh
#
# Copyright (C) 2021-2026 12X
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

BASEDIR="$(dirname $(readlink -f "$0"))"
. $BASEDIR/pathinfo.sh
. $BASEDIR/libsysinfo.sh

# $1:error_message
abort() {
    echo "$1"
    echo "! Uperf installation failed."
    exit 1
}

# $1:file_node $2:owner $3:group $4:permission $5:secontext
set_perm() {
    chown $2:$3 $1
    chmod $4 $1
    chcon $5 $1
}

# $1:directory $2:owner $3:group $4:dir_permission $5:file_permission $6:secontext
set_perm_recursive() {
    find $1 -type d 2>/dev/null | while read dir; do
        set_perm $dir $2 $3 $4 $6
    done
    find $1 -type f -o -type l 2>/dev/null | while read file; do
        set_perm $file $2 $3 $5 $6
    done
}

install_uperf() {
    echo "- Finding platform specified config"
    echo "- ro.board.platform=$(getprop ro.board.platform)"
    echo "- ro.product.board=$(getprop ro.product.board)"

    # 12X build is dedicated for 8EG5 (SM8850/Kaanapali). Use fixed profile
    # to avoid install-time detection failures across OEM property variants.
    local cfgname="sdm8g5"
    [ -f "$MODULE_PATH/config/$cfgname.json" ] || abort "! Missing $cfgname.json in module package."

    local soc_blob
    soc_blob="$(getprop ro.soc.model) $(getprop ro.board.platform) $(getprop ro.product.board) $(getprop ro.boot.hardware)"
    soc_blob="$(echo "$soc_blob" | tr '[:upper:]' '[:lower:]')"
    if ! echo "$soc_blob" | grep -qE 'sm8850|kaanapali|8[[:space:]]*elite'; then
        echo "! Warning: device properties do not look like 8EG5."
        echo "! Using forced profile: $cfgname"
    else
        echo "- Selected profile: $cfgname"
    fi

    echo "- Uperf config is located at $USER_PATH"
    mkdir -p $USER_PATH
    mv -f $USER_PATH/uperf.json $USER_PATH/uperf.json.bak
    cp -f $MODULE_PATH/config/$cfgname.json $USER_PATH/uperf.json
    [ ! -e "$USER_PATH/perapp_powermode.txt" ] && cp $MODULE_PATH/config/perapp_powermode.txt $USER_PATH/perapp_powermode.txt
    rm -rf $MODULE_PATH/config

    set_perm_recursive $BIN_PATH 0 0 0755 0755 u:object_r:system_file:s0
}

echo ""
echo "* Uperf-12X"
echo "* Author: 12X"
echo "* Version: 2026.04.19.14"
echo ""

echo "- Installing uperf"
install_uperf
