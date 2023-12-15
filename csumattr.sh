#!/usr/bin/bash
#
# The script originated from: https://gist.github.com/tsmetana/15b9bc7a7f5d529fbcfd689b3b65cc58
#
# Set/check SHA256 file checksum stored in the file's extended attributes
#

csum_attr="user.csum.sha256"
mtime_attr="user.csum.mtime"
check_path="."
action=""

usage()
{
	printf \
"Usage:
$0 -a|-c|-p|-r|-h path

 -a   Add checksum to the file, if it doesn't have it yet
 -u   Update checksum of the file, add if it doesn't have it yet
 -c   Compare the stored checksum with the SHA256 hash of the file
 -p   Print the stored SHA256 checksum
 -P   Print the stored SHA256 checksum in coreutils format
 -m   Print the stored file modification time at the point of computing
      the checksum
 -r   Remove the checksum and modification time extended attributes from
      the file
 -h   Print this help

The SHA256 checksums are stored in the $csum_attr extended file attribute.
Additionally, last modification time at the point of computing the checksum
is stored in the $mtime_attr extended file attribute. This allows to test
whether the file was legitimately modified since the checksum was computed
or whether it was corrupted.

If <path> is a directory it is traversed recursively.\n" >&2
}

check_file()
{
	local filename="$1"

	local -i mtime="$(stat -c "%Y" "$filename")"
	if [[ $? != 0 ]]
	then
		printf "$filename: Failed to stat modification time\n" >&2
		err=${err:-1}
		return
	fi

	local -i mtime_attr="$(getfattr --only-values -n $mtime_attr "$filename" 2>/dev/null)"
	if [[ $? != 0 ]]
	then
		printf "$filename: Modification time attribute not found\n" >&2
		err=${err:-1}
		return
	fi

	if [[ $mtime > $mtime_attr ]]
	then
		printf "$filename: Checksum is outdated\n" >&2
		err=2
		return
	fi

	local sum_attr="$(getfattr --only-values -n $csum_attr "$filename" 2>/dev/null)"
	if [[ $? != 0 ]]
	then
		printf "$filename: Checksum attribute not found\n" >&2
		err=${err:-1} # prevent overwriting err
		return
	fi

	local sum_line="$(openssl dgst -sha256 -r -- "$filename")"
	if [[ $? != 0 ]]
	then
		printf "$filename: Failed to compute checksum\n" >&2
		err=${err:-1}
		return
	fi

	local sum="${sum_line%% *}"
	if [ "${sum,,}" == "${sum_attr,,}" ]
	then
		printf "$filename: OK\n"
	else
		printf "$filename: FAILED\n"
		printf "$filename: Checksum mismatch (stored: ${sum_attr,,}, actual: ${sum,,})\n" >&2
		err=3
	fi
}

update_checksum()
{
	local filename="$1"
	local -i update="$2"

	local -i mtime="$(stat -c "%Y" "$filename")"
	if [[ $? != 0 ]]
	then
		printf "$filename: Failed to stat modification time\n" >&2
		err=${err:-1}
		return
	fi

	if [[ $update == 0 ]]
	then
		getfattr -n $csum_attr "$filename" >/dev/null 2>&1
		if [[ $? == 0 ]]
		then
			printf "$filename: Checksum attribute found, skipping\n" >&2
			return
		fi
	fi

	printf "Updating checksum for: \'${filename}\'...\n" >&2

	local sum_line="$(openssl dgst -sha256 -r -- "$filename")"
	if [[ $? != 0 ]]
	then
		printf "$filename: Failed to compute checksum\n" >&2
		err=${err:-1}
		return
	fi

	setfattr -n $mtime_attr -v "$mtime" "$filename" && setfattr -n $csum_attr -v "${sum_line%% *}" "$filename"
}

remove_attrs()
{
	local filename="$1"

	printf "Removing checksum from: \'${filename}\'\n" >&2
	setfattr -x $mtime_attr "$filename"
	setfattr -x $csum_attr "$filename"
}

print_checksum()
{
	local filename="$1"
	local -i coreutils_format="$2"

	local sum="$(getfattr --only-values -n $csum_attr "$filename")"
	if [[ $? == 0 ]]
	then
		if [[ $coreutils_format == 0 ]]
		then
			printf "$sum\n"
		else
			printf "$sum *$filename\n"
		fi
	fi
}

print_mtime()
{
	local filename="$1"

	local mtime="$(getfattr --only-values -n $mtime_attr "$filename")"
	if [[ $? == 0 ]]
	then
		printf "$mtime\n"
	fi
}

process_file()
{
	local filename="$1"

	case $action in
		"add")
			update_checksum "$filename" 0
			;;
		"update")
			update_checksum "$filename" 1
			;;
		"check")
			check_file "$filename"
			;;
		"remove")
			remove_attrs "$filename"
			;;
		"print_csum")
			print_checksum "$filename" 0
			;;
		"print_csum_coreutils")
			print_checksum "$filename" 1
			;;
		"print_mtime")
			print_mtime "$filename"
			;;
	esac

	return ${err:-0}
}

# main
while getopts "aucvhrpPm" opt; do
	case $opt in
		a)
			action="add"
			;;
		u)
			action="update"
			;;
		c)
			action="check"
			;;
		r)
			action="remove"
			;;
		p)
			action="print_csum"
			;;
		P)
			action="print_csum_coreutils"
			;;
		m)
			action="print_mtime"
			;;
		h)
			usage
			exit 0
			;;
		*)
			usage
			exit 1
			;;
	esac
done

if [[ -z "$action" ]]
then
	printf "The action option must be specified.\n\n" >&2
	usage
	exit 1
fi

shift $((OPTIND-1))
check_path="$1"

if [[ -d "$check_path" ]]
then
	find "$check_path" -type f -print0 | while read -d $'\0' esc_file
	do
		process_file "$esc_file" || break
	done;
elif [[ -f "$check_path" ]]
then
	process_file "$check_path"
else
	printf "Error: file not found: $check_path\n" >&2
	exit 2
fi

# returns the error code from process_file
