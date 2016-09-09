# Implementing Seamphores in Bash script

Semaphores are mechanisms for controlling access to shared resources in a multi-tasking environment. Semaphores can be used to solve a variety of programming problems. For example, systems administrators might use semaphores to:

*    Ensure that only one instance of a particular cron job is running.
*    Limit the use of a program to N concurrent users because of licensing restrictions.
*    Guarantee that critical administration tasks are performed by only one person at a time.
*    Manage resource utilization by allowing up to N instances of a program to run in parallel. 

Semaphores were first described by Dijkstra in 1965. From his viewpoint, a semaphore is an object comprising:

*    An integer value representing the number of resources that are free.
*    A set or queue of processes waiting for a resource.
*    The operations Init, P, and V. 

The Init operation initializes the value of a semaphore. When a process needs a resource, the P operation (which comes from the word "proberen" and means "to test" in Dijkstra's native Dutch language) tests the value of the semaphore and decrements the value if a resource is available. When the value of a semaphore is zero, processes attempting to grab a resource must wait until one becomes available. The V operation (from "verhogen", which means "to increment") frees a resource by incrementing the value of the semaphore.

A semaphore that has only two values (0 and 1) is a binary semaphore, while semaphores that are initialized with a value greater than 1 are called counting semaphores. 

## The script (semaphore.sh)

My choice of options -P and -V reflects Dijkstra's original work (though others have used DOWN and UP. or WAIT and SIGNAL. to refer to the P and V operations). When the -P and -V options are used together, the order in which the options appear on the command line determines which operation is performed first.

The -q option can be used to place processes that are waiting for a resource in a queue. When a resource becomes available, the process at the head of the queue gets it. Without the -q option, the order in which waiting processes obtain a resource is indeterminate.

By default, users have their own set of semaphores that are isolated from the semaphores in other user spaces. Semaphores may be shared among users by specifying an alternate user space using the -u option. User spaces are implemented as directories, so ensure that the directory representing the user space has the appropriate permissions by using the -o and -m options if necessary.

When the -P option is used to grab a resource, the semaphore process, by default, associates its parent process id with the obtained resource (see the function grab_resource). Since a process that has a resource could terminate without freeing the resource, a function called wipe_semaphore periodically checks each busy resource to determine whether the process that grabbed the resource is still running; if it isn't, the resource is automatically released. In some situations, it might be necessary to override the default behavior and specify a parent process id using the -p option. For example, if a program places jobs in the background and the parent process terminates before the children do, then you might need to use the -p option since orphaned processes inherit ppid 1. 

## High-Level Implementation

A semaphore must be initialized before its value can be incremented or decremented. This can be done explicitly by calling semaphore with the -I option. Otherwise, the semaphore is implicitly initialized with a value of 1 the first time the -P option is used. In both cases, the Init_semaphore function, Listing 2, is called to perform the initialization.

When using the -P option without the -q option, the semaphore script calls keep_trying, Listing 3. Without the -t option, the program loops until a resource is obtained. The -t option allows the program to time out if all resources are busy. With the -q option, the program calls wait_in_queue, which calls keep_trying once the process reaches the head of a queue.

Keep_trying calls P_semaphore, Listing 4, which checks the value of the semaphore to determine whether any resources are free at that moment in time. If there are no free resources, P_semaphore checks to see how many seconds have elapsed since the semaphore was last wiped. If the number of seconds exceeds the value of WIPE_INTERVAL, the semaphore is wiped again. Wiping the semaphore frees resources that are still being held by processes that have terminated.

If the value of the semaphore is greater than zero when P_semaphore is called, then the function iterates through the numbered resources, trying to grab one. As soon as a resource is obtained, the function returns success. Regardless of the value returned by get_semaphore_value, each resource could be busy when P_semaphore tries to grab it; if this is the case, then P_semaphore returns a failure code after testing each resource individually.

When the semaphore script is called with the -V option, the V_semaphore function, Listing 5, tries to free one semaphore resource. A resource is freed if and only if the process id associated with a busy resource matches the pid value passed to the V_semaphore function.

## Low-Level Implementation

Semaphores are one of three basic mechanisms typically used to implement Interprocess Communication (IPC). In the implementation of our semaphore script, polling and the filesystem are surrogates for the other two primitives: messages and shared memory.

When a program calls the semaphore script to obtain a resource, the process appears to block until a resource is obtained. To achieve this effect, the semaphore script polls the value of the semaphore. If the value is zero, then the script calls the sleep command before checking again. In other semaphore implementations, the V operation may signal one or more blocked processes to wake up after incrementing the value of the semaphore. Polling keeps the implementation simple without adding significant overhead compared to the cost of implementing the semaphore in the shell to begin with.

Directories, symbolic links, and regular files allow processes to share data structures. This is analogous to shared memory. The first three levels of the directory tree used to implement a semaphore are as follows:

user-specified-directory

The user-specified-directory contains a file (Resources, containing the number of resources controlled by the semaphore) and a subdirectory (Semaphore). Semaphore names must be unique. The data structures associated with a particular semaphore are implemented by the directory tree rooted at user-specified-directory. This directory contains the following files and subdirectories:

Resources
Semaphore/
        0 -> pidX
        1 -> pidY
        n -> pidZ

The following functions hide these low-level implementation details from the functions that call them:

    is_initialized  -- Determines whether a semaphore has been initialized by checking to see if the file /tmp/<user>/<semaphore>/num_resources contains a positive integer.
    set_num_resources -- Called by Init_semaphore to initialize a semaphore's value. An integer representing the initial value of the semaphore is written to the file /tmp/<user>/<semaphore>/num_resources.
    get_num_resources -- Prints a semaphore's initial value, which is read from the file /tmp/<user>/<semaphore>/num_resources.
    get_semaphore_value -- Prints the current value of a semaphore. The value is calculated by subtracting the number of resources in use (a count of the number of symbolic links in /tmp/<user>/<semaphore>/resources/) from the semaphore's initial value, stored in /tmp/<user>/<semaphore>/num_resources.
    get_resource_holder -- Prints the process id associated with a particular resource. The function calls get_link_target -- to obtain the target of the symbolic link /tmp/<user>/<semaphore>/resources/<n>.
    grab_resource -- Attempts to obtain a particular resource. The function must essentially test the semaphore's value and decrement the value if a resource is available, all in a single atomic step. This is accomplished by attempting to create the symbolic link user-specified-directory/Semaphore/Resource-Number. Michael Wang discusses this technique in detail in "lock_unlock -- Creating and Removing a Lock File" (http://www.unixreview.com/documents/s=1344/ur0402g/).
    return_resource -- Frees a resource, thus incrementing a semaphore's value, by deleting the symbolic link user-specified-directory/Semaphore/Resource-Number. 

## Caveats

The main advantage of the semaphore script lies in how easily other scripts can use it to solve concurrency problems. On the other hand, you need to watch out for certain security, performance, and correctness pitfalls.

Permissions on the directories and files used to implement various data structures are a potential security concern. For example, if users have permission to write to a semaphore's resources directory, they can launch a "denial of resource" attack by creating symbolic links in the resources directory.

Any shell script implementation of a semaphore is inefficient compared to semaphores provided by the operating system. The degree to which this is a problem depends on the performance requirements of the programs that use the semaphore script, as well as the impact the script has on overall system performance. In general, the performance impact of a single semaphore is proportional to the number of resources the semaphore has, and the number of processes that are waiting for a resource.

Efforts have been made to identify and address performance bottlenecks. 

As previously mentioned, programmers must be careful when placing jobs in the background, since the background job could be inherited by pid 1. This could lead to unexpected results if the parent process id is not specified explicitly using the -p option. The init process (pid 1) typically runs indefinitely, so a resource that is held by pid 1, must be freed manually ( -V -p pid switches).

Despite these caveats, semaphore is a powerful script. When used judiciously, it provides a convenient and reliable way to solve a variety of shared resource problems. 
