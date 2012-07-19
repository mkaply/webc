#!/bin/bash
source /etc/webc/webc.conf

cmdline_has debug && set -x

sub_literal() {
  awk -v str="$1" -v rep="$2" '
  BEGIN {
    len = length(str);
  }

  (i = index($0, str)) {
    $0 = substr($0, 1, i-1) rep substr($0, i + len);
  }

  1'
}


# Create a file to store dynamic iceweasel options
prefs=/etc/iceweasel/pref/webc-boot.js
cat > "$prefs" <<EOF
// This file is autogenerated based on cmdline options by live-config.sh. Do
// not edit this file, your changes will be overwriting on the next reboot!

EOF

# If printing support is not installed, prevent printing dialogs from being
# shown
if ! dpkg -s cups 2>/dev/null >/dev/null; then
	echo '// Print support not included, disable print dialogs' >> "$prefs"
	echo 'lockPref("print.always_print_silent", true);' >> "$prefs"
	echo 'lockPref("print.show_print_progress", false);' >> "$prefs"
fi

process_options()
{
link="/usr/lib/iceweasel/extensions/webconverger"

# Make sure we use a default closeicon, because the default does not have X on the last tab
cmdline | grep -qs "closeicon=" || /etc/webc/iwcloseconfig.sh activefix

for x in $( cmdline ); do
	case $x in

	debug)
		echo "webc ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
		;;

	chrome=*)
		chrome=${x#chrome=}
		dir="/etc/webc/iceweasel/extensions/${chrome}"
		test -d $dir && {
			test -e $link && rm -f $link
			logs "switching chrome to ${chrome}"
			ln -s $dir $link
		}
		;;

	locale=*)
		locale=${x#locale=}
		echo "lockPref(\"general.useragent.locale\", \"${locale}\");" >> "$prefs"
		echo "lockPref(\"intl.accept_languages\", \"${locale}, en\");" >> "$prefs"
		;;

	closeicon=*) # For toggling the close icons in iceweasel (bit OTT tbh)
		/etc/webc/iwcloseconfig.sh ${x#closeicon=}
		;;

	cron=*)
		cron="$( echo ${x#cron=} | sed 's,%20, ,g' )"		
		cat <<EOC > /etc/cron.d/live-config
SHELL=/bin/bash
PATH=/sbin:/bin:/usr/sbin:/usr/bin
$cron
EOC
		;;

	homepage=*)
		homepage="$( echo ${x#homepage=} | sed 's,%20, ,g' )"
		echo "lockPref(\"browser.startup.homepage\", \"$(echo $homepage | awk '{print $1}')\");" >> "$prefs"
		;;

	esac
done

# Make sure /home has noexec and nodev, for extra security.
# First, just try to remount, in case /home is already a separate filesystem
# (when using persistence, for example).
mount -o remount,noexec,nodev /home || (
	# Turn /home into a tmpfs. We use a trick here: after the mount, this
	# subshell will still have the old /home as its current directory, so
	# we can still read the files in the original /home. By passing -C to
	# the second tar invocation, it does a chdir, which causes it to end
	# up in the new filesystem. This enables us to easily copy the
	# existing files from /home into the new tmpfs.
	cd /home
	mount -o noexec,nodev -t tmpfs tmpfs /home
	tar -c . | tar -x -C /home
)

stamp=$( git show $webc_version | grep '^Date')

test -f ${link}/content/about.xhtml.bak || cp ${link}/content/about.xhtml ${link}/content/about.xhtml.bak
cat ${link}/content/about.xhtml.bak |
sub_literal 'OS not running' "${webc_version} ${stamp}" |
sub_literal 'var aboutwebc = "";' "var aboutwebc = \"$(echo ${install_qa_url} | sed 's,&,&amp;,g')\";" > ${link}/content/about.xhtml
}

update_cmdline() {
	SECONDS=0
	while true
	do
		wget --timeout=5 -t 1 -q -O /etc/webc/cmdline.tmp "$config_url" && break
		test $? = 8 && break # 404
		test $SECONDS -gt 15 && break
		sleep 1
	done
	
	# A configuration file always has a homepage
	grep -qs homepage /etc/webc/cmdline.tmp && mv /etc/webc/cmdline.tmp /etc/webc/cmdline
	touch /etc/webc/cmdline
}

until test -p $live_config_pipe # wait for xinitrc to trigger an update
do
    sleep 0.25 # wait for xinitrc to create pipe
done

source "/etc/webc/webc.conf"
cmdline_has noconfig || update_cmdline
process_options

echo ACK > $live_config_pipe

# live-config should restart via inittab and get blocked 
# until $live_config_pipe is re-created
