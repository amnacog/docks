## Description
A script to simplify the way to interact with dockers container

### Features
- restart a dead container in no time
- each container are aware of any containers (dns hosts)
- backup containers volume and configuration locally or upload them on s3
- light script to install anywhere

# Usage

```
$~> docks
usage: services start|stop|restart|status|build|update|list|log|self-update <services> <opts>
services: manage the containers

Options:

start|stop|restart <services> : Manipulations around services
	[--rm|-r]	: Erase the previously running container if so / rebuild the image
	[--verbose|-v]	: Display the verbose output (behind the scenes)
	[--force-pull|-f]	: Always pull the image tag before commands
	[--dependency|-d]	: Check/Start dependents containers before
build <services>	: Build the service with docker of choosen service
push <services>	: Push the service of choosen service
reset <services>	: Stop the container, rebuild and start it
status <services>	: Sh ow the running services
enter  <services>	: Enter interactivly inside container
update 			: Update the containers resolve ip's
list [-c]		: List the availables services
log [--color|-c]	: Logging containers (need ccze)
self-update		: Check/Install latest version of Docks

offered apps: *registered containers listed there*
```

# Installation

###1 - Get

```bash
wget https://raw.githubusercontent.com/Amnacog/docks/master/docks.sh > docks.sh;chmod +x docks.sh
```

###2 - Script Configuration

at the first launch, it will create a `.docks-config` under the same directory.
Edit it as you want...

###3 - Containers configuration

> Containers dir tree:

```
containers folder  
│
└───┬─ prefix.apache
    │   │INFO
    │   │start.sh
    │
    ├─ prefix.nginx
    │   │Dockerfile
    │   │INFO
    │   │start.sh
    │   ├─ app
    │      │...
    │
    └───...
```

- `start.sh`:
	contains the docker run command with some injected environment variables    
	eg:

	```bash
	$~> cat start.sh
	docker run \
		-d \
		-h container.sample.com \
		--restart=always \
		-v $PWD/volume/data:/data \
		-v $LOGDIR:/logs \
		--name $NAME \
		$IMAGE
	```

 - `INFO`:
    contains the image configuration (build version run backup)
    eg:
    
    ```bash
	NAME="sample_container" # container to run
	IMAGE="nginx"           # image name to build
	VERSION="0.1"           # image tag to build
	DEPENDS="some_child"
	
	#backups
	VOLUME_DIR="app"        # folder to backup 
	BACKUP_DIRS="data"      #filter inside 'app' folder. unset if not wanted
    ```
 
 - `Dockerfile`:
    contains the docker script to build




###4 - Run !

> Example:

```
	$~> docks build nginx
	Building nginx image
	Configuring nginx image finished
	
	$~> docks start nginx
	Starting nginx container (new) finished
	Updating container's ip finished
	
	#wait, nginx is dead ??
	$~> docks status nginx
	[KO] nginx is not running.
	
	#ooh right.. Easy !
	$~> docks restart nginx
	Removing nginx container (dead) finished
	Starting nginx container (new) finished
	Updating container's ip finished
		
	$~> docks status nginx
	[OK] nginx is running on 172.17.0.1


	$~> docks enter nginx
	root@container.sample.com:/# ps x
	PID TTY      STAT    TIME COMMAND
     1 ?         S      0:00 nginx: master process nginx
     2 ?         Ss     0:00 bash
     3 ?         R+     0:00 ps x 
```


More to come..
