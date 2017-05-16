#!/bin/bash
#set -x
#set -o functrace

RESOURCES_FILENAME=Resources
RESOURCES_DIRNAME=Semaphore
declare -a resources_taken

assert_semaphore(){
    if [ ! -d $1 ]; then
    	echo "$1 is not valid semphore"
	exit 3
    fi
    if [ ! -e $1/${RESOURCES_FILENAME} ]; then
	echo "$1 is not valid semphore"
	exit 4
    fi
    if [ ! -d $1/${RESOURCES_DIRNAME} ]; then
	echo "$1 is not valid semphore"
	exit 5
    fi
}

create_directories(){
    local semaphore=$1

    mkdir -p ${semaphore}/${RESOURCES_DIRNAME}
    if [ $? -ne 0 ]; then
	echo "could not mkdir -p ${semaphore}/${RESOURCES_DIRNAME}"
	exit 6
    fi
    return 0
}

get_resource_holder(){
    # Echos the process id (pid) of the process that currently has a
    # particular resource.

    local FUNC_NAME=get_resource_holder
    local semaphore=$1
    local resource_num=$2
    local pid
    local resource=$semaphore/$RESOURCES_DIRNAME/$resource_num

    assert_semaphore $semaphore

    if [[ -L $resource ]]; then
	pid=$(get_link_target $resource)
	if [[ -n $pid ]];  then
	    if [ $pid -gt 0 ]; then
		echo $pid
		return 0
	    fi
	fi
    elif [[ -f $resource ]]; then
	rm -f $resource # regular files shouldn't exist
    fi
    return 1
}

get_link_target(){
    # Echos the target filename that a symbolic link references. Returns 0
    # if $1 is a symbolic link; otherwise, returns 1.

    local FUNC_NAME=get_link_target
    local link=$1
    local target

    if [[ -L $link ]];  then
	line=$(ls -l $link 2>&-)
	target=${line##*'-> '}
	if [[ -n $target ]]; then
	    echo $target
	    return 0
	else
	    echo "race condition: $link disappeared or changed!"
	fi
    fi
    echo "$link is not a symbolic link"
    return 1
}

get_busy_resources(){
    # Returns the list of busy resources

    local FUNC_NAME=get_busy_resources
    local semaphore=$1

    assert_semaphore $semaphore

    local link_dir=$semaphore/$RESOURCES_DIRNAME

    echo $(ls -1 $link_dir | sed -e 's,@,,g')
    resources_taken=( $(ls -1 $link_dir | sed -e 's,@,,g') )
    if [ ${#resources_taken[@]} -gt 0 ]; then
	return 0
    else
	return 1
    fi

}

grab_resource(){
    # Caveat Emptor! The implementation of semaphore hinges on the
    # behavior  of  the  ln  command.  To  implement  a  semaphore
    # correctly, the test of a semaphore's value  and  the  decre-
    # menting  of  this  value must be an atomic operation. In the
    # function grab_resource, the act of creating a symbolic  link
    # does  both  things at once. If the ln command is successful,
    # then the semaphore's count is effectively tested and  decre-
    # mented in one atomic step.

    local FUNC_NAME=grab_resource
    local semaphore=$1
    resource_num=$2
    local symbolic_link=$semaphore/$RESOURCES_DIRNAME/$resource_num
    pid=$3

    assert_semaphore $semaphore
    if [ -L $symbolic_link ]; then
	echo 1
    else
	ln -s $pid $symbolic_link >&- 2>&-
	echo $?
    fi
}

return_resource(){
    # Frees a resource by deleting the symbolic link that represents the
    # fact that the resource is currently in use. See also grab_resource.

    local FUNC_NAME=return_resource
    local semaphore=$1
    resource_num=$2
    pid=$3

    if [[ $pid = "$(get_resource_holder $semaphore $resource_num)" ]]; then
	#echo "Returning resource $resource_num"
	rm -f $semaphore/$RESOURCES_DIRNAME/$resource_num
	return $?
    else
	return 1
    fi
}


Init_semaphore(){
    # Init_semaphore sets the number of resources for a semaphore.

    local FUNC_NAME=Init_semaphore
    local semaphore=$1
    local num_resources=$2
    local already
    local dirAlready

    is_initialized $semaphore
    ready=$?
    if [ ! ${already} ]; then
	create_directories $semaphore
	dirAlready=$?
	if [ ! ${dirAlready} ]; then
	    return 1
	fi
    fi
    set_num_resources $semaphore $num_resources
    return $?
}

keep_trying(){
    # Keep "trying" the semaphore until a resource is obtained or until the
    # program times out.

    local FUNC_NAME=keep_trying
    local semaphore=$1
    num_resources=$2
    pid=$3
    remaining_tries=$4

    assert_semaphore $semaphore

    while [ ! P_semaphore $semaphore $num_resources $pid ]; do
	sleep $SLEEP_SECONDS
	if [ $remaining_tries -gt 0 ]; then
	    if [ $remaining_tries == 0 ]; then
		total=$(($TIMEOUT_TRIES*$SLEEP_SECONDS))
		echo "PID $$ timed out after $TIMEOUT_TRIES tries and $total seconds."
		return 1
	    else
		remaining_tries=$(( $remaining_tries - 1 ))
	    fi
	fi
    done
    return 0
}

P_semaphore(){
    # P_semaphore tries to grab a resource. The function effectively
    # decrements the count or value of the semaphore if one is obtained.
    # Returns 0 if a resource is obtained; otherwise, returns 1.

    local FUNC_NAME=P_semaphore
    local semaphore=$1
    local num_resources=$2
    local pid=$3
    local grab_attempt

    assert_semaphore $semaphore

    local semaphore_value=$(get_semaphore_limit $semaphore)
    echo "Semaphore $semaphore has $num_resources resource(s)."
    echo "Value of semaphore $semaphore is: $semaphore_value"

    echo "Trying to grab a resource from semaphore $semaphore ..."
    resource_num=0
    while [ $resource_num -lt $semaphore_value ]; do
	grab_attempt=$(grab_resource $semaphore $resource_num $pid)
	if [[ grab_attempt -eq 0 ]]; then
	    echo "PID $pid grabbed resource $resource_num."
	    return 0
	else
	    echo "Resource $resource_num was in use."
	    resource_num=$(($resource_num+1))
	fi
    done
    echo "All resources for semaphore $semaphore were in use."
    return 1
}

V_semaphore(){
    # V_semaphore effectively increments the count or value of a semaphore.
    # The function returns one semaphore resource iff $pid currently has
    # one; otherwise the semaphore's number of resources is incremented by
    # one.

    local FUNC_NAME=V_semaphore
    local semaphore=$1
    local num_resources=$2
    local pid=$3
    local resource_num=0
    local any_resources

    assert_semaphore $semaphore

    echo "Trying to return a resource to semaphore $semaphore ..."
    any_sources=$(get_busy_resources $semaphore)
    for resource_num in ${any_sources[@]}; do
	if [ $(return_resource $semaphore $resource_num $pid) ]; then
	    echo "PID $pid returned resource $resource_num."
	    return 0
	fi
    done

    return 1
}

is_initialized(){
    # Returns 0 if a semaphore exists and is initialized; otherwise, returns
    # 1. The semaphore $semaphore exists and is initialized if the symbolic
    # link $semaphore/$RESOURCES_FILENAME exists and points to a
    # "filename" that is a non-negative integer.

    local FUNC_NAME=is_initialized
    local semaphore=$1
    local resources_file=$semaphore/$RESOURCES_FILENAME

    if [[ -f $resources_file ]]; then
	local resources = $(cat -s $resources_file)
	if [ ${resources} -gt 0 ]; then
	    echo "Semaphore $semaphore is initialized."
	    return 0
	fi
    fi
    echo "Semaphore $semaphore is not initialized."
    return 1
}

set_num_resources(){
    # Sets the number of resources for the semaphore. Returns 0 if the
    # number of resources was set; otherwise, returns non-zero.

    local FUNC_NAME=set_num_resources
    local semaphore=$1
    num_resources=$2
    local resources_file=$semaphore/$RESOURCES_FILENAME

    if  [ $num_resources -gt 0 ]; then
	echo $num_resources > $resources_file
	return $?
    else
	return 1
    fi
}

get_num_resources(){
    # Echos the number of resources that a semaphore has. (See also
    # Init_semaphore).  Return the contents of the specified semaphore's
    # resource file, and return 0 if the semaphore has been initialized;

    local FUNC_NAME=get_num_resources
    local semaphore=$1
    local resources_file=$semaphore/$RESOURCES_FILENAME

    assert_semaphore $semaphore

    num_resources=$(cat -s $resources_file)
    echo ${num_resources:-0}
}

get_semaphore_value(){
    local FUNC_NAME=get_sem_value
    local semaphore=$1
    local resources_file=$semaphore/$RESOURCES_FILENAME
    local resources_dir=$semaphore/$RESOURCES_DIRNAME

    assert_semaphore $semaphore

    num_resources=$(cat -s $resources_file)
    num_taken_resources=$(ls -1 $resources_dir | wc -l)
    echo $(( $num_resources - $num_taken_resources ))
}

get_semaphore_limit(){
    local FUNC_NAME=get_sem_limit
    local semaphore=$1
    local resources_file=$semaphore/$RESOURCES_FILENAME
    local resources_dir=$semaphore/$RESOURCES_DIRNAME

    assert_semaphore $semaphore

    num_resources=$(cat -s $resources_file)
    echo $(( $num_resources ))
}

timed_P_semaphore(){
    local FUNC_NAME=timed_P_semaphore
    local semaphore=$1
    local value=$2
    local pid=$3
    local time_to_wait=$4
    local current_wait=0

    assert_semaphore $semaphore

    while [ $current_wait -lt $time_to_wait ]; do
	P_semaphore ${semaphore} ${value} ${pid}
	if [ $? -eq 0 ]; then #we got it
	    return 0
	else #we did not get it, so sleep
	    sleep 1
	    current_wait=$(($current_wait + 1))
	fi
    done

    return 1
}

#
#SYNOPSIS
#
#semaphore [other options] [user options] [directives] name
#
#semaphore [other options]
#
Usage(){
    echo "OPTIONS"
    echo   "-I number -- Initialize the semaphore and sets resources number to number."
    echo ""
    echo "  -P -- Retrieve a resource and decrement the value of the semaphore."
    echo "        Wait until a resource becomes available if -W specified or no"
    echo "        wait if -W not specified."
    echo ""
    echo "  -V -- Increment the value of the semaphore if and only if the calling"
    echo "        process has an available resource."
    echo ""
    echo "  -d -- Execute semaphore in debug mode. Additional error messages may be"
    echo "        displayed. Function tracing is turned on."
    echo ""
    echo "  -l -- List information about the semaphore(s)."
    echo ""
    echo "  -m -- mode -- Set the permissions mode on the directory used to implement"
    echo "        the user space."
    echo ""
    echo "  -o -- owner[:group] -- Set the ownership on the directory used to"
    echo "        implement the user space."
    echo ""
    echo "  -W - Wait time -- Use with -P "
    echo ""
    echo "  -p - pid -- Use with -V to explicitly specify the pid associated with a"
    echo "        resource to be freed. Although not recommended, -p may also be used"
    echo "        with -P to explicitly specify the OPERANDS"
    echo ""
    echo "  name -- Identifies a semaphore by name. "
}

# main
#
Number=0
Init=1
Wait=1
Signal=1
List=1
Mode=1
ModeValue=0
Owner=1
OwnerValue=0
Pid=1
PidValue=0
WaitTime=1
WaitTimeValue=0
if [[ $# -eq 1 ]]; then #Only -h (help) is allowed here
    Usage
    if [ "$1" == "-h" ]; then
	exit 0
    else
	exit 1
    fi
fi

while [[ $# -gt 1 ]]; do #last arg is semaphore
    switch="$1"
    case $switch in
	-I|--number)
	    Number=$2
	    Init=0
	    shift
	    ;;
	-P|--wait)
	    Wait=0
	    ;;
	-W|--wait-time)
	    WaitTime=0
	    WaitTimeValue=$2
	    shift
	    ;;
	-V|--signal)
	    Signal=0
	    ;;
	-l|--list)
	    List=0
	    ;;
	-m|--mode)
	    ModeValue="$2"
	    Mode=0
	    shift
	    ;;
	-o|--owner)
	    OwnerValue="$2"
	    Owner=0
	    shift
	    ;;
	-p|--pid)
	    PidValue="$2"
	    Pid=0
	    shift
	    ;;
	-h|--help)
	    Usage
	    exit 0
	    ;;
	*)
	    echo "unknown option '${switch}'."
	    exit 1
	    ;;
    esac
    shift
done



Semaphore=$1

if [ -z ${Semaphore} ]; then
    Usage
    exit 2
fi

if [ ${List} -eq 0 ]; then
    get_semaphore_value ${Semaphore}
    exit 0
elif [ ${Init} -eq 0 ]; then
    Init_semaphore ${Semaphore} ${Number}
    exit 0
elif [ ${Wait} -eq 0 ]; then
    if [ ${WaitTime} -eq 0 ]; then
	timed_P_semaphore ${Semaphore} 1 $$ ${WaitTimeValue}
    else
	P_semaphore ${Semaphore} 1 $$
    fi
    exit 0
elif [ ${Signal} -eq 0 ]; then
    if [ ${Pid} -eq 0 ]; then
	V_semaphore ${Semaphore} 1 ${PidValue}
    else
	V_semaphore ${Semaphore} 1 $$
    fi
    exit 0
fi
