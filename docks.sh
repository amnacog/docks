#!/usr/bin/env bash

cd $(dirname $0)

script=$(basename $(echo $0))
origin=$PWD
shell=$(basename $(echo $SHELL))
arch=$(dpkg --print-architecture)

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
builddir=\"/sample/buildctx\"
datadir=\"/sample/data\"
logsdir=\"/sample/log\"
maxsaves=\"10\"
dependency=\"true\"
" > $conf_dir/.docks-config
	exit
}

services="$(echo ${servicesdir}/*/ | tr ' ' '\n' | grep $prefix | rev | cut -d/ -f2 | cut -d. -f1 | rev | tr '\n' ' ')"

function check {
	out=$(docker info 2>&1 >/dev/null)
	ret=$?
	if [ $ret -ne 0 -o ! -z "$out" ]; then
		echo -e "\e[0;31mDocker error: $out\e[0m"
		exit 1
	fi
}

function start {
	containerdir=$servicesdir/${prefix}$1
	[ -z "$1" ] && help && exit -1
	prefixlog=''
	[ ! -z "$2" ] && prefixlog="[$2] "

	if [ -d $containerdir ]; then
		cd $containerdir
		unset PRE_CMD PRE_OUT_CMD POST_CMD POST_OUT_CMD LOGDIR DATADIR CREATE_DATADIR NAME IMAGE VERSION CONTAINER HOST DEPENDS
		source INFO
		export $(cut -d= -f1 INFO | grep -v \#)

		if [ -f $containerdir/Dockerfile -a -z "$(docker ps -a --filter "name=${prefix}$1$" --filter status=running -q)" ]; then
			CONTAINER="$(docker ps -a --filter "name=${prefix}$1$" -q)"

			export IMAGE="$([ -z "$IMAGE" ] && echo ${provider}/$(echo $NAME | tr _ /) || echo $IMAGE)"
			export LOGDIR="$logsdir/${prefix}$NAME"
			export DATADIR="$datadir/${prefix}$NAME"
			export VERSION=$([ -z "$VERSION" ] && echo latest || echo $VERSION)
			export HOST="$(echo "$prefix"| tr '.' '-')$NAME"
			export NAME="${prefix}$NAME"

			$remove && [ ! -z "$CONTAINER" ] && waiter docker rm ${prefix}$1 "Removing $1 container"

			if $forcepull; then
				waiter docker pull ${provider}/${IMAGE}:${VERSION} "${prefixlog}Pulling image ${provider}/${IMAGE}:${VERSION}"
			fi
			[ ! -d "$LOGDIR" ] && waiter mkdir -p $LOGDIR "${prefixlog}Creating logdir for $1"
			[ ! -d "$DATADIR" -a ! "$CREATE_DATADIR" != "false" ] && waiter mkdir -p $DATADIR "${prefixlog}Creating datadir for $1"
			[ ! -z "$PRE_OUT_CMD" ] && waiter eval "$PRE_OUT_CMD" "${prefixlog}Executing pre out task"
			[ ! -z "$PRE_CMD" ] && waiter docker exec ${NAME} $PRE_CMD "${prefixlog}Executing pre in task"

			if $dependency || [ "$2" != "dep" ]; then
				for service in $DEPENDS; do
					if ! status $service | grep -q OK && [ "$3" != "$1" ]; then
						( start $service dep $1 )
					elif [ "$3" == "$1" ]; then
						echo dependency $1 has self dependence with $3
					fi
				done
			fi

			if ! $remove && [ ! -z "$CONTAINER" ]; then
				waiter docker start $CONTAINER "${prefixlog}Starting $1 container (old)"
			else
				export bakimg="$IMAGE:$VERSION"
				export IMAGE=$bakimg
				waiter ./start* "${prefixlog}Starting $1 container (new)"
				if [ $ret -ne 0 -a $ret -ne 125 ]; then
					export bakori=$IMAGE
					export IMAGE=$bakimg
					waiter ./start* "${prefixlog}Starting $1 container (new)"
					waiter docker tag ${provider}/$bakimg ${provider}/$bakori:latest "${prefixlog}Tagged $IMAGE to latest"
				fi
			fi
			[ ! -z "$POST_CMD" ] && waiter docker exec ${NAME} /usr/bin/env sh -c "$POST_CMD" "${prefixlog}Execing internal post scripts"
			[ ! -z "$POST_OUT_CMD" ] && waiter eval "$POST_OUT_CMD" "${prefixlog}Execing external post scripts"
		elif [ -f $containerdir/docker-compose.yml ]; then
			$remove && waiter docker-compose rm -f -v "${prefixlog}Removing $1 containers pool"
			waiter ./start* "${prefixlog}Starting $1 containers (new)"
		elif [ ! -f $containerdir/start* ]; then
			echo "Cannot start/stop an intermediate container."
		elif [ ! -z "$CONTAINER" ]; then
			echo "<start> $1 already running."
		fi
		unset PRE_CMD PRE_OUT_CMD POST_CMD POST_OUT_CMD LOGDIR DATADIR CREATE_DATADIR NAME IMAGE VERSION CONTAINER HOST DEPENDS
		cd - >/dev/null
	else
		echo "<start> $1 not found."
	fi
}

function stop {
	containerdir=${servicesdir}/${prefix}$1
	[ -z "$1" ] && help && exit -1
	if [ -d $containerdir ]; then
		unset NAME STOP_PRE_CMD STOP_PRE_OUT_CMD STOP_POST_CMD STOP_POST_OUT_CMD
		cd $containerdir && source INFO && export $(cut -d= -f1 INFO | grep -v \#)
		if [ -f $containerdir/Dockerfile* ]; then
			if [ ! -z "$(docker ps -a --filter "name=${prefix}$NAME$" --filter status=running -q)" ]; then
				[ ! -z "$STOP_PRE_CMD" ] && waiter docker exec ${NAME} $STOP_PRE_CMD "${prefixlog}Executing pre in task"
				[ ! -z "$STOP_PRE_OUT_CMD" ] && waiter eval "$STOP_PRE_OUT_CMD" "${prefixlog}Executing pre out task"
				waiter docker stop -t 4 ${prefix}$NAME "Stopping $1 container"
				$remove && waiter docker rm -f ${prefix}$NAME "Removing $1 container"
			elif [ ! -z "$(docker ps -a --filter "name=${prefix}$NAME" -aq)" ] && $remove; then
				$remove && waiter docker rm -f ${prefix}$NAME "Removing $1 container (dead)"
			else
				echo "<stop> $1 not running."
			fi
		elif [ -f $containerdir/docker-compose.yml ]; then
			waiter docker-compose down --remove-orphans "Stopping $1 containers pool"
			$remove && waiter docker-compose rm -f -v "Removing $1 containers pool"
		fi

		[ ! -z "$STOP_POST_OUT_CMD" ] && waiter eval "$STOP_POST_OUT_CMD" "${prefixlog}Execing external post scripts"

		unset NAME STOP_PRE_CMD STOP_PRE_OUT_CMD STOP_POST_OUT_CMD
		cd - >/dev/null
	else
		echo "<stop> $1 not found."
	fi
}

function build {
	[ -z "$1" ] && help && exit -1
	containerdir=$servicesdir/${prefix}$1
	if [ -d $containerdir -a -f $containerdir/Dockerfile ]; then
		cd $containerdir && source INFO && export $(cut -d= -f1 INFO | grep -v \#) NAME="$(echo $NAME | tr _ /)"
		base_image=$(cat Dockerfile | grep -m 1 ^FROM | grep -v $prefix | cut -d' ' -f2)

		if $remove && [ ! -z "$base_image" ]; then
			waiter docker pull $base_image "Pulling $1 base image"
		fi

		if echo "$builddir" | grep -q '%service%'; then
			build_dir=${builddir/'%service%'/${prefix}$1}
		else
			build_dir=$builddir/${prefix}$1
		fi
		[ ! -d "$build_dir" -a ! -z "$CREATE_DATADIR" ] && waiter mkdir -p $build_dir "Creating datadir for $1"

		waiter docker build --network=host -t $provider/$NAME:$VERSION $($remove && echo "--no-cache") -f $containerdir/Dockerfile --rm --force-rm $(echo $OPTS) $build_dir "Building $1 image"

		if $slim && [ ! -z "$(which slim)" ]; then
			waiter slim --report off build --target $provider/$NAME:$VERSION --tag $provider/$NAME:slim "Optimizing $1 image"
			if [ $ret -eq 0 ] && $remove; then
				baseImageId=$(docker images $base_image -q)
				builtImageTags=$(docker images $provider/$NAME --format "{{.ID}} {{.Repository}}:{{.Tag}}" | grep -v slim | cut -d' ' -f2 | tr '\n' ' ')
				waiter eval "docker rmi -f $builtImageTags $baseImageId; \
					docker tag $provider/$NAME:slim $provider/$NAME:$VERSION; \
					docker tag $provider/$NAME:slim $provider/$NAME:latest" "Configuring $1 image"
			else
				[ ! -z "$VERSION" ] && waiter docker tag $provider/$NAME:$VERSION $provider/$NAME:latest "Configuring $1 image"
			fi
		else
			[ ! -z "$VERSION" ] && waiter docker tag $provider/$NAME:$VERSION $provider/$NAME:latest "Configuring $1 image"
		fi


		cd - >/dev/null && unset NAME VERSION OPTS
	elif [ -d $containerdir -a ! -f $containerdir/Dockerfile ]; then
		echo "$1 meant to be use by another image."
	else
		echo "$1 not found."
	fi
}

function push {
	[ -z "$1" ] && help && exit -1
	containerdir=$servicesdir/${prefix}$1
	if [ -d $containerdir -a -f $containerdir/INFO ]; then
		cd $containerdir && source INFO && export $(cut -d= -f1 INFO | grep -v \#) NAME="$(echo $NAME | tr _ /)"
		if ! [ -z "$(docker images -q ${provider}/${NAME}:${VERSION})" ]; then
			waiter docker push ${provider}/${NAME}:${VERSION} "Pushing ${NAME}:${VERSION}"
			if $always; then
				waiter docker push ${provider}/${NAME}:latest "Pushing ${NAME}:latest"
			fi
		else
			echo "$1 not builded yet."
			if $forcepull; then
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
	list="$(docker inspect -f '{{.Name}}/{{range .NetworkSettings.Networks}}{{.IPAddress}}/{{.GlobalIPv6Address}}{{end}}' $(docker ps -q) | grep -v '\/\/' | sed 's/^.//')"
	#list="$(docker network inspect bridge | jq -r '.[0].Containers')"
	gw="$(docker network inspect bridge | jq -r '.[0].IPAM.Config[0].Gateway')"
	hosts=$(echo -e "$gw$(printf %20s)ans.docker\n")

	while IFS='\n' read -r line; do
		IFS='/' read -r name v4 v6 <<< "$line"
		alias_file=$(cat $(echo $name | cut -d' ' -f2)/INFO | grep HOST_ALIAS)
		[ ! -z "$alias_file" ] && HOST_ALIAS=" "$(echo $alias_file | cut -d'"' -f2)
		hosts_aliases=${name}${HOST_ALIAS}
		v4len="$(echo -n $v4 | wc -c)"
		v6len="$(echo -n $v6 | wc -c)"
		[ -z "$v4" ] || hosts=$(echo -e "$hosts\n$v4$(printf %$((30 - $v4len))s)$hosts_aliases\n${v6:-"#"}$(printf %$((30 - $v6len))s)$hosts_aliases")
		unset HOST_ALIAS
		((count++))
	done <<< "$list"

	echo -e "127.0.0.1 alwaysadavalidline\n${hosts}" > ${servicesdir}/docker.hosts
	echo wrote config
}

function upgrade {
	[ -z "$1" ] && help && exit -1
	containerdir=$servicesdir/${prefix}$1
	if [ -d $containerdir -a -f $containerdir/INFO -a -f $containerdir/Dockerfile ]; then
		cd $containerdir && source INFO && export $(cut -d= -f1 INFO | grep -v \#) NAME="$(echo $NAME | tr _ /)"
		sourceImage=$(cat Dockerfile | grep FROM  | grep -v \# | cut -d' ' -f2)

		if ! [ -z "$sourceImage" ]; then
			localDigest=$(docker image inspect $sourceImage | jq -r '.[0].Id')
			remoteDigest=$(docker manifest inspect --verbose $sourceImage | jq -r "if type == \"array\" then .[] | select(.Descriptor.platform.architecture == \"$arch\" and .Descriptor.platform.os == \"linux\" ) .SchemaV2Manifest.config.digest else .SchemaV2Manifest.config.digest end")

			if [ ! -z "$remoteDigest" ] && [ "$localDigest" != "$remoteDigest" ]; then
				echo "$1: remote image differs, rebuilding..."
				export remove=true
				build $1
				return 2
			fi
			echo "$1: nothing to do."
			return 1
		else
			echo "$1: could not find source image."
			return 1
		fi
	else
		echo "$1: not found."
		return 1
	fi
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
	findshell='for shl in "zsh" "bash" "ash" "sh";do r=$(which $shl);if [ ! -z "$r" ]; then $r; break; fi; done'

	if [ -d $servicesdir/${prefix}$1 -a ! -z "$(docker ps -a --filter "name=${prefix}$1$" --filter status=running -q)" ]; then
		docker exec -it ${prefix}$1 /usr/bin/env sh -c "$findshell"
	else
		image="$(echo $1 | tr _ /)"
		echo -e "\e[0;33mWarning\e[0m: this is a temporary container"
		docker run -it --rm $provider/$image:latest /usr/bin/env sh -c "$findshell"
	fi
}

function log {
	if [ -d $servicesdir/${prefix}$1 ]; then
		[ -z "$(docker ps -a --filter "name=${prefix}$1$" --filter status=running -q)" ] && echo -e "\e[0;33mWarning\e[0m: Container is not running."
		$color && { a="ccze";b="-m";c="ansi";d="-o";e="nolookups"; } || a="cat"
		$forcepull && { t="--tail"; n=20; }
		cd $servicesdir/${prefix}$1 && source INFO && export $(cut -d= -f1 INFO | grep -v \#) && cd - >/dev/null
		docker logs ${prefix}$NAME -f $t $n 2>&1| $a $b $c $d $e
	fi
}

function updateme {
	curl -skL "https://raw.githubusercontent.com/Amnacog/docks/${1:-master}/docks.sh" > $origin/$script
}

function waiter {
	len=$(($#-1))
	prog=${@:1:$len}
	pid=""
	cleanup() {
		tput cnorm &>/dev/null
		kill -13 $pid &>/dev/null
		exit 1
	}
	if ! $verbose; then
		tput civis &>/dev/null
		trap cleanup INT
		anim=( '⠋' '⠙' '⠸' '⢰' '⣠' '⣄' '⡆' '⠇')
		i=0
		echo -ne "\r${@: -1}  "
		while :; do
			echo -ne "\r${@: -1} ${anim[$i]} "
			[ $((++i)) -gt 7 ] && i=0
			sleep 0.1
		done &
		pid=$!
		log=$($prog 2>&1)
		ret=$?
		kill -13 $pid
		if [ $ret -ne 0 ] && [ $ret -ne 2 ]; then
			echo -e "\r${@: -1} \e[0;31m✗\n$log\e[0m"
		elif [ $ret -eq 2 ]; then
			echo -e "\r${@: -1} \e[0;32m✓\e[0m\n$log\e[0m"
		else
			echo -e "\r${@: -1} \e[0;32m✓\e[0m"
		fi
		tput cnorm &>/dev/null
		trap - INT
	else
		echo "exec: $prog"
		$prog
		ret=$?
	fi
}

function help {
	echo -e "usage: $script start|stop|restart|status|build|update|list|log|self-update <services> <opts> \n$script: manage the containers

Options:

\e[0;33mstart|stop|restart \e[3;34m<services> \e[0m: Manipulations around services
\t\e[2;35m[--rm|-r]\t\e[0m: Erase the previously running container if so / rebuild the image
\t\e[2;35m[--verbose|-v]\t\e[0m: Display the verbose output (behind the scenes)
\t\e[2;35m[--force-pull|-f]\t\e[0m: Always pull the image tag before commands
\t\e[2;35m[--dependency|-d]\t\e[0m: Check/Start dependents containers before
\e[0;33mbuild \e[3;34m<services>\e[0m\t: Build the service with docker of choosen service
\e[0;33mpush \e[3;34m<services>\e[0m\t: Push the service of choosen service
\e[0;33mreset \e[3;34m<services>\e[0m\t: Stop the container, rebuild and start it
\e[0;33mstatus \e[3;34m<services>\e[0m\t: Sh ow the running services
\e[0;33menter  \e[3;34m<services>\e[0m\t: Enter interactivly inside container
\e[0;33mupdate \e[0m\t\t\t: Update the containers resolve ip's
\e[0;33mlist \e[2;35m[-c]\e[0m\t\t: List the availables services
\e[0;33mlog \e[2;35m[--color|-c]\e[0m\t: Logging containers (need ccze)
\e[0;33mself-update\e[0m\t\t: Check/Install latest version of Docks
\noffered apps: $services"
}

function main {
	case "$1" in
		reset)check;build $2;stop $2;save=$remove;remove=false;start $2;remove=$save;$0 update;;
		start)check;start $2;$0 update;;
		stop)check;stop $2;;
		status)check;status $2;;
		restart)check;stop $2;start $2;$0 update;;
		build)check;build $2;;
		push)check;push $2;;
		tag)check;tag $2 $3 $4;;
		update)waiter update "Updating container's ip";;
		upgrade)waiter upgrade $2 "Checking for newer image";;
		enter)check;enter $2;;
		log)check;log $2;;
		list)echo ${services[@]};;
		backup)backup $2;;
		self-update)waiter updateme $2 "Upgrading docks";;
		*)help;;
	esac
}

#start
[ -z "$1" ] && help && exit

[[ $@ == *'-v'* || $@ == *'--verbose'* ]] && export verbose=true || export verbose=false
[[ $@ == *'-f'* || $@ == *'--force-pull'* ]] && export forcepull=true || export forcepull=false
[[ $@ == *'-r'* || $@ == *'--rm'* ]] && export remove=true || export remove=false
[[ $@ == *'-d'* || $@ == *'--dependency'* || $dependency == 'true' ]] && export dependency=true || export dependency=false
[[ $@ == *'-c'* || $@ == *'--color'* ]] && export color=true || export color=false
[[ $@ == *'-a'* || $@ == *'--always'* ]] && export always=true || export always=false
[[ $@ == *'-s'* || $@ == *'--slim'* ]] && export slim=true || export slim=false

export ret;

if [ ! -z "$2" ]; then
	for arg in ${@:2:$(($#-1))}; do
		echo $arg | grep -qv "\-" && main $1 $arg || true
	done
else
	main $1 $2
fi
