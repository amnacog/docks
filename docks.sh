#!/usr/bin/env bash

cd $(dirname $0)
script=$(basename $(echo $0))
origin=$PWD
shell=$(basename $(echo $SHELL))
[ "$HOME" == "/" ] && export HOME="/root"

([ ! -f $origin/.docks-config ] && [ ! -w $origin ]) && conf_dir="$HOME" || conf_dir="$origin"
[ -f $conf_dir/.docks-config ] && {
	source $conf_dir/.docks-config
} || {
	echo -e "Writing new configuration file in '$conf_dir/.docks-config'\nPlease change the configuration.."
	echo -e "prefix=\"docks.\"
provider=\"docks\"
backbucket=\"\"
backupdir=\"/sample/backups\"
servicesdir=\"/sample/services\"
builddir=\"/sample/build\"
logsdir=\"/sample/log\"
maxsaves=\"10\"
writehost=\"true\"
" > $conf_dir/.docks-config
	exit
}

services="$(echo ${servicesdir}/*/ | tr ' ' '\n' | rev | cut -d/ -f2 | cut -d. -f1 | rev | tr '\n' ' ')"

function start {
	[ -z "$1" ] && help && exit -1
	export CONTAINER="$(docker ps -a --filter "name=${prefix}$1$" -q)"
	if [ -d $servicesdir/${prefix}$1 ] && [ -f $servicesdir/${prefix}$1/start* ] && [ -z "$(docker ps -a --filter "name=${prefix}$1$" --filter status=running -q)" ]; then
		$remove && waiter docker rm ${prefix}$1 "Removing $1 container"
		cd $servicesdir/${prefix}$1 && source INFO && \
		export $(cut -d= -f1 INFO | grep -v \#) IMAGE="$([ -z "$IMAGE" ] && (echo $NAME | tr _ /) || echo $IMAGE)" LOGDIR="$logsdir/${prefix}$NAME"
		VERSION=$([ -z "$VERSION" ] && echo latest || echo $VERSION)
		if $forcepull; then
			waiter docker pull ${provider}/${IMAGE}:${VERSION} "Pulling image ${provider}/${IMAGE}:${VERSION}"
		fi
		[ ! -d "$LOGDIR" ] && waiter mkdir -p $LOGDIR "creating logdir for $1"
		[ ! -z "$PRE_CMD" ] && docker exec ${prefix}${NAME} bash -c "$PRE_CMD" &>/dev/null
		[ ! -z "$PRE_OUT_CMD" ] && eval "$PRE_OUT_CMD" &>/dev/null
		if ! $remove && [ ! -z "$CONTAINER" ]; then
			waiter docker start $CONTAINER "Starting $1 container (old)"
		else
			export bakimg="$IMAGE:$VERSION"
			export HOST="$(echo "$prefix"| tr '.' '-')$NAME" NAME="${prefix}$NAME"
			export IMAGE=$bakimg
			waiter ./start* "Starting $1 container (new)"
			if [ $ret -ne 0 ] && [ $ret -ne 125 ]; then
				export bakori=$IMAGE
				export IMAGE=$bakimg
				waiter ./start* "Starting $1 container (new)"
				waiter docker tag ${provider}/$bakimg ${provider}/$bakori:latest "Tagged $IMAGE to latest"
			fi
		fi
		[ ! -z "$POST_CMD" ] && docker exec ${prefix}${NAME} bash -c "$POST_CMD" &>/dev/null
		[ ! -z "$POST_OUT_CMD" ] && eval "$POST_OUT_CMD" &>/dev/null
		cd - >/dev/null unset POST_CMD POST_OUT_CMD LOGDIR NAME IMAGE
	elif [ -d $servicesdir/${prefix}$1 ] && [ ! -f $servicesdir/${prefix}$1/start* ]; then
		echo "Cannot start/stop an intermediate container."
		exit 1
	elif [ ! -z "$CONTAINER" ]; then
		echo "<start> $1 already running."
		exit 1
	else
		echo "<start> $1 not found."
		exit -1
	fi
}

function stop {
	[ -z "$1" ] && help && exit -1
	if [ -d $servicesdir/${prefix}$1 ]; then
		cd $servicesdir/${prefix}$1 && source INFO && export $(cut -d= -f1 INFO | grep -v \#) && cd - >/dev/null
		if [ -d $servicesdir/${prefix}$1 ] && [ ! -z "$(docker ps -a --filter "name=${prefix}$NAME$" --filter status=running -q)" ]; then
			waiter docker stop -t 4 ${prefix}$NAME "Stopping $1 container"
			$remove && waiter docker rm -f ${prefix}$NAME "Removing $1 container"
		elif [ ! -z "$(docker ps -a --filter "name=${prefix}$NAME" -aq)" ] && $remove; then
			$remove && waiter docker rm -f ${prefix}$NAME "removing $1 container (dead)"
		else
			echo "<stop> $1 not running."
		fi
	else
		echo "<stop> $1 not found."
	fi
}

function build {
	[ -z "$1" ] && help && exit -1
	if [ -d $builddir/${prefix}$1 ] && [ -f $builddir/${prefix}$1/Dockerfile ]; then
		cd $builddir/${prefix}$1 && source INFO && export $(cut -d= -f1 INFO | grep -v \#) NAME="$(echo $NAME | tr _ /)"
		waiter docker build -t $provider/$NAME:$VERSION $($remove && echo "--no-cache") --rm $(echo $OPTS) $builddir/${prefix}$1 "Building $1 image"
		[ ! -z "$VERSION" ] && waiter docker tag $provider/$NAME:$VERSION $provider/$NAME:latest "Configuring $1 image"
		cd - >/dev/null && unset NAME VERSION OPTS
	elif [ -d $builddir/${prefix}$1 ] && [ ! -f $builddir/${prefix}$1/Dockerfile ]; then
		echo "$1 meant to be use by another image."
	else
		echo "$1 not found."
	fi
}

function push {
	[ -z "$1" ] && help && exit -1
	if [ -d $builddir/${prefix}$1 ] && [ -f $builddir/${prefix}$1/INFO ]; then
		cd $builddir/${prefix}$1 && source INFO && export $(cut -d= -f1 INFO | grep -v \#) NAME="$(echo $NAME | tr _ /)"
		if ! [ -z "$(docker images -q ${provider}/${NAME}:${VERSION})" ]; then
			waiter docker push ${provider}/${NAME}:${VERSION} "Pushing ${NAME}:${VERSION}"
			if $always; then
				waiter docker push ${provider}/${NAME}:latest "Pushing ${NAME}:latest"
			fi
		else
			echo "$1 not builded yet."
			if $force; then
				build $1
			fi
		fi
	else
		echo "$1 not found."
	fi
}

function status {
	function print {
		if $color; then
			docker inspect ${prefix}$1 | jq -r '.[0].NetworkSettings.IPAddress'
		else
		[ $2 -eq 0 ] && echo -e "[\033[0;32mOK\033[0m] $1 is running on $(docker inspect ${prefix}$1 | jq -r '.[0].NetworkSettings.IPAddress')" ||
			echo -e "[\033[0;31mKO\033[0m] $1 is not running."
		fi
	}
	if [ -z "$1" ]; then
		list=$(docker ps)
		for dir in $services; do
			if [ -f $servicesdir/${prefix}$dir/start.sh ]; then
				echo "$list" | grep "$(echo $dir)" | grep -q "Up"
				print $dir $?
			fi
		done
	else
		echo $services | tr _ / | grep -q "$1" || { echo "$1 not found." && return; }
		docker ps | grep $1 | grep -q "Up"
		print "$1" $?
	fi
}

function update {
	hosts="127.0.0.1	localhost $(echo "$prefix"| tr '.' '-')-replace
::1		localhost ip6-localhost ip6-loopback
fe00::0		ip6-localnet
ff00::0		ip6-mcastprefix
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
"
	IFS="
"
	list="$(docker ps --format "{{.ID}} {{.Names}} {{.Image}}")"

	for conts in $list; do
		ip="$(docker inspect $(echo $conts | cut -d' ' -f1) | jq -r '.[0].NetworkSettings.IPAddress')"
		[ -z "$ip" ] || hosts="$(echo -e "$hosts\n$ip\t$(echo $conts | cut -d' ' -f2)")"
	done
	for conts in $list; do
		[ "$(echo "$conts" | cut -d' ' -f2)" == "${prefix}nginx" ] && extra=";pkill -HUP -f dnsmasq"
		echo "$hosts" | sed "s/replace/$(echo "$conts" | cut -d' ' -f2 | rev | cut -d'.' -f1 | rev)/g" | docker exec -i $(echo "$conts" | cut -d' ' -f1) /bin/bash -c "cat > /etc/hosts$extra"
		unset extra
	done

	if [ "$writehost" == "true" ]; then
		roothosts="$(cat /etc/hosts | sed '/##docks/q')"
		if echo "$roothosts" | grep "##docks" &>/dev/null; then
			echo -e "${roothosts}\n${hosts}" > /etc/hosts
		else
			echo -e "\n##docks\n${hosts}" >> /etc/hosts
		fi
	fi

	IFS=" "
}

function mbackup {
	backs=$(find ${backupdir}/${prefix}$1 -name "$2*.tar.gz")
	occback=$(echo "$backs" | wc -l)
	if [ $occback -eq 0 ]; then return;
	elif [ $occback -ge $maxsaves ]; then
		waiter rm $(ls -t1 ${backupdir}/${prefix}$1/$2*.tar.gz 2>/dev/null | tail -n1) "$service -> limit exceed [$maxsaves] (removing oldest save)"
		((occback--))
	fi
	for file in $backs; do
		[ $occback -le 0 ] && break
		if [ $occback -eq 1 ]; then
			mv ${backupdir}/${prefix}$1/$2.tar.gz ${backupdir}/${prefix}$1/$2.${occback}.tar.gz
		else
			mv ${backupdir}/${prefix}$1/$2.$((occback - 1)).tar.gz ${backupdir}/${prefix}$1/$2.${occback}.tar.gz
		fi
		((occback--))
	done
}

function backup {
	if [ -d $servicesdir/${prefix}$1 ]; then
		service="$1";
	elif [ "$1" == "all" ]; then
		service="$services"
	fi

	[ ! -f $conf_dir/.docks-hashbdb ] && echo "{}" > $conf_dir/.docks-hashbdb
	hashbdb="$(cat $conf_dir/.docks-hashbdb)"

	for service in $service; do
		if cd $servicesdir/${prefix}$service && [ -f INFO ] && source INFO && [ ! -z "$BACKUP_DIRS" ]; then
			[ ! -z "$BACKUP_CMD" ] && waiter eval "$BACKUP_CMD" "$service -> executing custom command"
			for dir in $BACKUP_DIRS; do
				ha=$(find ./$VOLUME_DIR/$dir -type f -exec md5sum {} \; | sort -k 34 | md5sum | cut -d' ' -f1)
				dirslug=$(echo "$dir" | tr -d '/' | tr -d '-' | tr -d '.')
				storedhash=$(echo "$hashbdb" | jq -r ".${service}.${dirslug}" 2>/dev/null)
				update=true
				if [ "$storedhash" != "null" ]; then
					if [ "$storedhash" == "$ha" ]; then
						echo "$service -> $dir matches (skipping)"
						update=false
					else
						echo "$service -> $dir differs"
					fi
				fi
				$update && {
					[ ! -d ${backupdir}/${prefix}${service} ] && waiter mkdir -p ${backupdir}/${prefix}${service} "$service -> creating folder" || mbackup "$service" "$dirslug"
					waiter tar cf ${backupdir}/${prefix}${service}/${dirslug}.tar.gz ./$VOLUME_DIR/$dir "$service -> Storing $dirslug"
					[ ! -z "$backbucket" ] && aws s3 sync --exclude '*' --include "${backupdir}/${prefix}${service}/${dirslug}.tar.gz" "${backupdir}" "s3://$backbucket"
					hashbdb=$(echo "$hashbdb" | jq -r ".${service}.${dirslug} = \"$ha\"" | tee $conf_dir/.docks-hashbdb)
				}
			done
			ha="$(find INFO Dockerfile start* -type f -exec md5sum {} \; | sort -k 34 | md5sum | cut -d' ' -f1)"
			storedhash=$(echo "$hashbdb" | jq -r ".${service}.configuration" 2>/dev/null)
			update=true
			if [ "$storedhash" == "null" ] || [ "$storedhash" != "$ha" ]; then
				[ ! -d ${backupdir}/${prefix}${service} ] && waiter mkdir -p ${backupdir}/${prefix}${service} "$service -> creating folder" || mbackup "$service" "$dirslug"
				waiter tar cf ${backupdir}/${prefix}${service}/configuration.tar.gz INFO Dockerfile start* "$service -> Storing configuration"
				[ ! -z "$backbucket" ] && aws s3 sync --exclude '*' --include "${backupdir}/${prefix}${service}/configuration.tar.gz" "${backupdir}" "s3://$backbucket"
				hashbdb=$(echo "$hashbdb" | jq -r ".${service}.configuration = \"$ha\"" | tee $conf_dir/.docks-hashbdb)
			fi
			unset VOLUME_DIR BACKUP_DIRS BACKUP_CMD
		fi
	done
}

function enter {
	if [ -d $servicesdir/${prefix}$1 ] && [ ! -z "$(docker ps -a --filter "name=${prefix}$1$" --filter status=running -q)" ]; then
		docker exec -it ${prefix}$1 bash
	else
		image="$(echo $1 | tr _ /)"
		echo -e "\e[0;33mWarning\e[0m: this is a temporary container"
		docker run -it --rm $provider/$image:latest bash
	fi
}

function log {
	if [ -d $servicesdir/${prefix}$1 ]; then
		[ -z "$(docker ps -a --filter "name=${prefix}$1$" --filter status=running -q)" ] && echo -e "\e[0;33mWarning\e[0m: Container is not running."
		$color && { a="ccze";b="-m";c="ansi"; } || a="cat"
		cd $servicesdir/${prefix}$1 && source INFO && export $(cut -d= -f1 INFO | grep -v \#) && cd - >/dev/null
		docker logs -f ${prefix}$NAME | $a $b $c
	fi
}

function updateme {
	curl -skL "https://raw.githubusercontent.com/Amnacog/docks/${1:-master}/docks.sh" > $origin/$script
}

function waiter {
	len=$(($#-1))
	prog=${@:1:$len}
	if ! $verbose; then
		tput civis
		trap "tput cnorm;exit" INT
		anim=( '/' '――' '\' '|' )
		i=0
		echo -ne "\r${@: -1}  "
		while :; do
			echo -ne "\r${@: -1} ${anim[$i]} "
			[ $((++i)) -gt 3 ] && i=0
			sleep 0.1
		done &
		pid=$!
		log=$($prog 2>&1)
		ret=$?
		kill -13 $pid
		[ $ret -ne 0 ] && echo -e "\r${@: -1} \e[0;31mfailed\n$log\e[0m" || echo -e "\r${@: -1} \e[0;32mfinished\e[0m"
		tput cnorm
		trap - INT
	else
		$prog
		ret=$?
	fi
}

function help {
	echo -e "usage: $script start|stop|restart|status|build|update <services> <opts> \n$script: manage the containers

Options:

\e[0;33mstart|stop|restart \e[3;34m<services> \e[0m: Manipulations around services
\t\e[2;35m[--rm|-r]\t\e[0m: Erase the previously running container if so / rebuild the image
\t\e[2;35m[--verbose|-v]\t\e[0m: Display the verbose output (behind the scenes)
\e[0;33mbuild \e[3;34m<services>\e[0m\t: Build the service with docker of choosen service
\e[0;33mpush \e[3;34m<services>\e[0m\t: Push the service of choosen service
\e[0;33mreset \e[3;34m<services>\e[0m\t: Stop the container, rebuild and start it
\e[0;33mstatus \e[3;34m<services>\e[0m\t: Sh ow the running services
\e[0;33menter  \e[3;34m<services>\e[0m\t: Enter interactivly inside containers
\e[0;33mupdate \e[0m\t\t\t: Update the containers resolve ip's
\e[0;33mlist \e[2;35m[-c]\e[0m\t\t: List the availables services
\e[0;33mlog \e[2;35m[--color|-c]\e[0m\t: Logging containers
\noffered apps: $services"
}

function main {
	case "$1" in
		reset)build $2;stop $2; unset remove;start $2;$0 update;;
		start)start $2;$0 update;;
		stop)stop $2;;
		status)status $2;;
		restart)stop $2;remove=false;start $2;$0 update;;
		build)build $2;;
		push)push $2;;
		tag)tag $2 $3 $4;;
		update)waiter update "Updating container's ip";;
		enter)enter $2;;
		log)log $2;;
		list)echo ${services[@]};;
		backup)backup $2;;
		self-update)waiter updateme $2 "Upgrading docks";;
		*)help;;
	esac
}

#start
[ -z "$1" ] && help && exit

opts="${@:3:$(($#-1))}"
echo "$opts"|grep -q "\-v\|\-\-verbose" || verbose=false
echo "$opts"|grep -q "\-f\|\-\-force-pull" && forcepull=true || forcepull=false
echo "$opts"|grep -q "\-r\|\-\-rm" && remove=true || remove=false
echo "$opts"|grep -q "\-c\|\-\-color" && color=true || color=false
echo "$opts"|grep -q "\-f\|\-\-force" && force=true || force=false
echo "$opts"|grep -q "\-a\|\-\-always" && always=true || always=false

export ret;

if [ ! -z "$2" ]; then
	for arg in ${@:2:$(($#-1))}; do
		echo $arg | grep -qv "\-" && main $1 $arg || true
	done
else
	main $1 $2
fi
