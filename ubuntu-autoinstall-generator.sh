#!/bin/bash
set -Eeuo pipefail

function cleanup() {
        trap - SIGINT SIGTERM ERR EXIT
        if [ -n "${tmpdir+x}" ]; then
                rm -rf "$tmpdir"
                log "🚽 Deleted temporary working directory $tmpdir"
        fi
}

trap cleanup SIGINT SIGTERM ERR EXIT
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
[[ ! -x "$(command -v date)" ]] && echo "💥 date command not found." && exit 1
today=$(date +"%Y-%m-%d")

function log() {
        echo >&2 -e "[$(date +"%Y-%m-%d %H:%M:%S")] ${1-}"
}

function die() {
        local msg=$1
        local code=${2-1} # Bash parameter expansion - default exit status 1. See https://wiki.bash-hackers.org/syntax/pe#use_a_default_value
        log "$msg"
        exit "$code"
}

function parse_params() {
    user_data_file=''
    meta_data_file=''
    source_iso=''
    destination_iso="${script_dir}/ubuntu-autoinstall-$today.iso"

    while :; do
        case "${1-}" in
        -s | --source)
                source_iso="${2-}"
                shift
                ;;
        -u | --user-data)
                user_data_file="${2-}"
                shift
                ;;
        -d | --destination)
                destination_iso="${2-}"
                shift
                ;;
        -m | --meta-data)
                meta_data_file="${2-}"
                shift
                ;;
        -?*) die "Unknown option: $1" ;;
        *) break ;;
        esac
        shift
    done

    if [[ -z "${user_data_file}" ]]; then
        die "💥 user-data file was not specified."
    fi
    if [[ ! -f "$user_data_file" ]]; then
        die "💥 user-data file could not be found."
    fi
    if [[ ! -f "$meta_data_file" ]]; then
        die "💥 meta-data file could not be found."
    fi

    if [[ ! -f "${source_iso}" ]]; then
        die "💥 Source ISO file could not be found."
    fi

    destination_iso=$(realpath "${destination_iso}")
    source_iso=$(realpath "${source_iso}")

    return 0
}

parse_params "$@"

tmpdir=$(mktemp -d)

if [[ ! "$tmpdir" || ! -d "$tmpdir" ]]; then
        die "💥 Could not create temporary working directory."
else
        log "📁 Created temporary working directory $tmpdir"
fi

log "🔎 Checking for required utilities..."
[[ ! -x "$(command -v xorriso)" ]] && die "💥 xorriso is not installed. On Ubuntu, install  the 'xorriso' package."
[[ ! -x "$(command -v sed)" ]] && die "💥 sed is not installed. On Ubuntu, install the 'sed' package."
[[ ! -x "$(command -v curl)" ]] && die "💥 curl is not installed. On Ubuntu, install the 'curl' package."
[[ ! -f "/usr/lib/ISOLINUX/isohdpfx.bin" ]] && die "💥 isolinux is not installed. On Ubuntu, install the 'isolinux' package."
log "👍 All required utilities are installed."

log "🔧 Extracting ISO image..."
xorriso -osirrox on -indev "${source_iso}" -extract / "$tmpdir" &>/dev/null
chmod -R u+w "$tmpdir"
rm -rf "$tmpdir/"'[BOOT]'
log "👍 Extracted to $tmpdir"

log "🧩 Adding autoinstall parameter to kernel command line..."
sed -i -e 's/---/ autoinstall  ---/g' "$tmpdir/isolinux/txt.cfg"
sed -i -e 's/---/ autoinstall  ---/g' "$tmpdir/boot/grub/grub.cfg"
sed -i -e 's/---/ autoinstall  ---/g' "$tmpdir/boot/grub/loopback.cfg"
log "👍 Added parameter to UEFI and BIOS kernel command lines."

log "🧩 Adding user-data and meta-data files..."
mkdir "$tmpdir/nocloud"
cp "$user_data_file" "$tmpdir/nocloud/user-data"
if [ -n "${meta_data_file}" ]; then
        cp "$meta_data_file" "$tmpdir/nocloud/meta-data"
else
        touch "$tmpdir/nocloud/meta-data"
fi
sed -i -e 's,---, ds=nocloud;s=/cdrom/nocloud/  ---,g' "$tmpdir/isolinux/txt.cfg"
sed -i -e 's,---, ds=nocloud\\\;s=/cdrom/nocloud/  ---,g' "$tmpdir/boot/grub/grub.cfg"
sed -i -e 's,---, ds=nocloud\\\;s=/cdrom/nocloud/  ---,g' "$tmpdir/boot/grub/loopback.cfg"
log "👍 Added data and configured kernel command line."

log "📦 Repackaging extracted files into an ISO image..."
cd "$tmpdir"
xorriso -as mkisofs -r -V "ubuntu-autoinstall-$today" -J -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin -boot-info-table -input-charset utf-8 -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat -o "${destination_iso}" . &>/dev/null
cd "$OLDPWD"
log "👍 Repackaged into ${destination_iso}"

die "✅ Completed." 0