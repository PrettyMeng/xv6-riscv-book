.chapter CH:FS "File system"
.ig
        is it process or kernel thread?

        the logging text (and some of the buffer text) assumes the reader
        knows a fair amount about how inodes and directories work,
        but they are introduced later.

	have to decide on processor vs CPU, i/o vs I/O.
	
	be sure to say buffer, not block 

	figure out a way to make the parallel between BUSY and locks clear
        maybe don't use sleep/wakeup but having something ref counts to avoid
        the race in bget.

	TODO: Explain the name sys_mknod.
	Perhaps mknod was for a while the only way to create anything?
	
	Mount
..  
.PP
The purpose of a file system is to organize and store data. File systems
typically support sharing of data among users and applications, as well as
.italic-index persistence
so that data is still available after a reboot.
.PP
The xv6 file system provides Unix-like files, directories, and pathnames
(see Chapter \*[CH:UNIX]), and stores its data on an IDE disk for
persistence (see Chapter \*[CH:TRAP]). The file system addresses
several challenges:
.IP \[bu]  
The file system needs on-disk data structures to represent the tree
of named directories and files, to record the identities of the
blocks that hold each file's content, and to record which areas
of the disk are free.
.IP \[bu] 
The file system must support
.italic-index "crash recovery" .
That is, if a crash (e.g., power failure) occurs, the file system must
still work correctly after a restart. The risk is that a crash might
interrupt a sequence of updates and leave inconsistent on-disk data
structures (e.g., a block that is both used in a file and marked free).
.IP \[bu]  
Different processes may operate on the file system at the same time,
and must coordinate to maintain invariants.
.IP \[bu]  
Accessing a disk is orders of magnitude slower than accessing
memory, so the file system must maintain an in-memory cache of
popular blocks.
.LP
The rest of this chapter explains how xv6 addresses these challenges.
.\"
.\" -------------------------------------------
.\"
.section "Overview"
.PP
The xv6 file system implementation is
organized in seven layers, shown in 
.figref fslayer .
The disk layer reads and writes blocks on an IDE hard drive.
The buffer cache layer caches disk blocks and synchronizes access to them,
making sure that only one kernel process at a time can modify the
data stored in any particular block.  The logging layer allows higher
layers to wrap updates to several blocks in a
.italic-index transaction ,
and ensures that the blocks are updated atomically in the
face of crashes (i.e., all of them are updated or none).
The inode layer provides individual files, each represented as an
.italic-index inode
with a unique i-number
and some blocks holding the file's data.  The directory
layer implements each directory as a special kind of
inode whose content is a sequence of directory entries, each of which contains a
file's name and i-number.
The pathname layer provides
hierarchical path names like
.code /usr/rtm/xv6/fs.c ,
and resolves them with recursive lookup.
The file descriptor layer abstracts many Unix resources (e.g., pipes, devices,
files, etc.) using the file system interface, simplifying the lives of
application programmers.
.figure fslayer
.PP
The file system must have a plan for where it stores inodes and
content blocks on the disk.
To do so, xv6 divides the disk into several
sections, as shown in 
.figref fslayout .
The file system does not use
block 0 (it holds the boot sector).  Block 1 is called the 
.italic-index "superblock" ; 
it contains metadata about the file system (the file system size in blocks, the
number of data blocks, the number of inodes, and the number of blocks in the
log).  Blocks starting at 2 hold inodes, with multiple inodes per block.  After
those come bitmap blocks tracking which data blocks are in use.
Most of the remaining blocks are data blocks; each is either marked
free in the bitmap block, or holds content for a file or directory.
The blocks at the end of the disk hold the logging layer's log.
.PP
The rest of this chapter discusses each layer, starting with the
buffer cache.
Look out for situations where well-chosen abstractions at lower layers
ease the design of higher ones.
.\"
.\" -------------------------------------------
.\"
.section "Buffer cache Layer"
.PP
The buffer cache has two jobs: (1) synchronize access to disk blocks to ensure
that only one copy of a block is in memory and that only one kernel thread at a time
uses that copy; (2) cache popular blocks so that they don't to be re-read from
the slow disk. The code is in
.code bio.c .
.PP
The main interface exported by the buffer cache consists of
.code-index bread
and
.code-index bwrite ;
the former obtains a
.italic-index buf
containing a copy of a block which can be read or modified in memory, and the
latter writes a modified buffer to the appropriate block on the disk.
A kernel thread must release a buffer by calling
.code-index brelse
when it is done with it.
.PP
The buffer cache synchronizes access to each block by allowing at most
one kernel thread to have a reference to the block's buffer. If one
kernel thread has obtained a reference to a buffer but hasn't yet
released it, other threads' calls to
.code bread
for the same block will wait.
Higher file system layers rely on the buffer cache's block
sychronization to help them maintain invariants.
.PP
The buffer cache has a fixed number of buffers to hold disk blocks,
which means that if the file system asks for a block that is not
already in the cache, the buffer cache must recycle a buffer currently
holding some other block. The buffer cache recycles the
least recently used buffer for the new block. The assumption is that
the least recently used buffer is the one least likely to be used
again soon.
.figure fslayout
.\"
.\" -------------------------------------------
.\"
.section "Code: Buffer cache"
.PP
The buffer cache is a doubly-linked list of buffers.
The function
.code-index binit ,
called by
.code-index main
.line main.c:/binit/ ,
initializes the list with the
.code-index NBUF
buffers in the static array
.code buf
.lines bio.c:/Create.linked.list/,/^..}/ .
All other access to the buffer cache refer to the linked list via
.code-index bcache.head ,
not the
.code buf
array.
.PP
A buffer has three state bits associated with it.
.code-index B_VALID
indicates that the buffer contains a copy of the block.
.code-index B_DIRTY
indicates that the buffer content has been modified and needs
to be written to the disk.
.code-index B_BUSY
indicates that some kernel thread has a reference to this
buffer and has not yet released it.
.PP
.code Bread
.line bio.c:/^bread/
calls
.code-index bget
to get a buffer for the given sector
.line bio.c:/b.=.bget/ .
If the buffer needs to be read from disk,
.code bread
calls
.code-index iderw
to do that before returning the buffer.
.PP
.code Bget
.line bio.c:/^bget/
scans the buffer list for a buffer with the given device and sector numbers
.lines bio.c:/Is.the.sector.already/,/^..}/ .
If there is such a buffer,
and the buffer is not busy,
.code-index bget
sets the
.code-index B_BUSY
flag and returns
.lines 'bio.c:/if...b->flags.&.B_BUSY/,/^....}/' .
If the buffer is already in use,
.code bget
sleeps on the buffer to wait for its release.
When
.code-index sleep
returns,
.code bget
cannot assume that the buffer is now available.
In fact, since 
.code sleep
released and reacquired
.code-index buf_table_lock ,
there is no guarantee that 
.code b 
is still the right buffer: maybe it has been reused for
a different disk sector.
.code Bget
must start over
.line bio.c:/goto.loop/ ,
hoping that the outcome will be different this time.
.ig
.figure bufrace
.PP
rtm says: this example doesn't really work: if one deleted
the goto, the code would continue on to the "recycle" loop instead
of returning the buffer found before the sleep. maybe we could present
the code for a different and broken implementation, and use that for
the example, but that seems a bit complex. in any case the end
of the previous paragraph explains the potential problems.
If
.code-index bget
didn't have the
.code goto
statement, then the race in 
.figref bufrace 
could occur.
The first process has a buffer and has loaded sector 3 in it.
Now two other processes come along. The first one does a 
.code get
for buffer 3 and sleeps in the loop for cached blocks.  The second one does a
.code get
for buffer 4, and could sleep on the same buffer but in the loop for freshly
allocated blocks because there are no free buffers and the buffer that holds 3
is the one at the front of the list and is selected for reuse.   The first
process releases the buffer and 
.code wakeup
happens to schedule process 3 first, and it will grab the buffer and load sector
4 in it.   When it is done it will release the buffer (containing sector 4) and
wakeup process 2.  Without the 
.code goto
statement process 2 will mark the buffer 
.code BUSY ,
and return from
.code bget ,
but the buffer contains sector 4, instead of 3.  This error could result in all
kinds of havoc, because sectors 3 and 4 have different content; xv6 uses them
for storing inodes.
..
.PP
If there is no cached buffer for the given sector,
.code-index bget
must make one, possibly reusing a buffer that held
a different sector.
It scans the buffer list a second time, looking for a buffer
that is not busy:
any such buffer can be used.
.code Bget
edits the buffer metadata to record the new device and sector number
and marks the buffer busy before
returning the buffer
.lines bio.c:/flags.=.B_BUSY/,/return.b/ .
Note that the assignment to
.code flags
not only sets the
.code-index B_BUSY
bit but also clears the
.code-index B_VALID
and
.code-index B_DIRTY
bits, thus ensuring that
.code bread
will read the block data from disk
rather than incorrectly using the buffer's previous contents.
.PP
Because the buffer cache is used for synchronization,
it is important that
there is only ever one buffer for a particular disk sector.
The assignments
.lines bio.c:/dev.=.dev/,/.flags.=.B_BUSY/
are only safe because 
.code bget 's
first loop determined that no buffer already existed for that sector,
and
.code bget
has not given up
.code buf_table_lock
since then.
.PP
If all the buffers are busy, something has gone wrong:
.code bget
panics.
A more graceful response might be to sleep until a buffer became free,
though there would then be a possibility of deadlock.
.PP
Once
.code-index bread
has returned a buffer to its caller, the caller has
exclusive use of the buffer and can read or write the data bytes.
If the caller does write to the data, it must call
.code-index bwrite
to write the changed data to disk before releasing the buffer.
.code Bwrite
.line bio.c:/^bwrite/
sets the 
.code-index B_DIRTY
flag and calls
.code-index iderw
to write
the buffer to disk.
.PP
When the caller is done with a buffer,
it must call
.code-index brelse
to release it. 
(The name
.code brelse ,
a shortening of
b-release,
is cryptic but worth learning:
it originated in Unix and is used in BSD, Linux, and Solaris too.)
.code Brelse
.line bio.c:/^brelse/
moves the buffer
to the front of the linked list
.lines 'bio.c:/b->next->prev.=.b->prev/,/bcache.head.next.=.b/' ,
clears the
.code-index B_BUSY
bit, and wakes any processes sleeping on the buffer.
Moving the buffer causes the
list to be ordered by how recently the buffers were used (meaning released):
the first buffer in the list is the most recently used,
and the last is the least recently used.
The two loops in
.code bget
take advantage of this:
the scan for an existing buffer must process the entire list
in the worst case, but checking the most recently used buffers
first (starting at
.code bcache.head
and following
.code next
pointers) will reduce scan time when there is good locality of reference.
The scan to pick a buffer to reuse picks the least recently used
buffer by scanning backward
(following 
.code prev
pointers).
.\"
.\" -------------------------------------------
.\"
.section "Logging layer"
.PP
One of the most interesting problems in file system design is crash
recovery. The problem arises because many file system operations
involve multiple writes to the disk, and a crash after a subset of the
writes may leave the on-disk file system in an inconsistent state. For
example, depending on the order of the disk writes, a crash during
file deletion may either leave a directory entry pointing to a free
inode, or it may leave an allocated but unreferenced inode. The latter is relatively
benign, but a directory entry that refers to a freed inode is
likely to cause serious problems after a reboot.
.PP
Xv6 solves the problem of crashes during file system operations with a
simple version of logging. An xv6 system call does not directly write
the on-disk file system data structures. Instead, it places a
description of all the disk writes it wishes to make in a 
.italic-index log 
on the disk. Once the system call has logged all of its writes, it writes a
special 
.italic-index commit
record to the disk indicating that the log contains
a complete operation. At that point the system call copies the writes
to the on-disk file system data structures. After those writes have
completed, the system call erases the log on disk.
.PP
If the system should crash and reboot, the file system code recovers
from the crash as follows, before running any processes. If the log is
marked as containing a complete operation, then the recovery code
copies the writes to where they belong in the on-disk file system. If
the log is not marked as containing a complete operation, the recovery
code ignores the log.  The recovery code finishes by erasing
the log.
.PP
Why does xv6's log solve the problem of crashes during file system
operations? If the crash occurs before the operation commits, then the
log on disk will not be marked as complete, the recovery code will
ignore it, and the state of the disk will be as if the operation had
not even started. If the crash occurs after the operation commits,
then recovery will replay all of the operation's writes, perhaps
repeating them if the operation had started to write them to the
on-disk data structure. In either case, the log makes operations
atomic with respect to crashes: after recovery, either all of the
operation's writes appear on the disk, or none of them appear.
.\"
.\"
.\"
.section "Log design"
.PP
The log resides at a known fixed location at the end of the disk.
It consists of a header block followed by a sequence
of updated block copies (``logged blocks'').
The header block contains an array of sector
numbers, one for each of the logged blocks. The header block
also contains the count of logged blocks. Xv6 writes the header
block when a transaction commits, but not before, and sets the
count to zero after copying the logged blocks to the file system.
Thus a crash midway through a transaction will result in a
count of zero in the log's header block; a crash after a commit
will result in a non-zero count.
.PP
Each system call's code indicates the start and end of the sequence of
writes that must be atomic; we'll call such a sequence a transaction,
though it is much simpler than a database transaction. Only one system
call can be in a transaction at any one time: other processes must
wait until any ongoing transaction has finished. Thus the log holds at
most one transaction at a time.
.PP
For simplicity, xv6 does not allow concurrent transactions.
Here's an example of the kind of problem it would have to
solve if it did allow them.
Suppose transaction X has written a modification to an
inode into the log. Concurrent transaction Y then reads a different
inode in the same block, updates that inode, writes the inode block to
the log, and commits. This is a disaster: the inode block that Y's
commit writes to the disk contains modifications by X, which has
not committed. A crash and recovery at this point would expose one
of X's modifications but not all, thus breaking the promise that
transactions are atomic.
.PP
A serious drawback of allowing only one transaction at a time
is that there can be no concurrency inside the file system:
even if two processes are using different files, they cannot
execute file system system calls in parallel, and one
cannot execute while the other process is waiting for the disk.
We plan to modify the logging layer to allow concurrent
transactions in a future version of xv6.
This is why
other parts of the file system code are designed for
concurrency (e.g., the buffer cache's 
.code B_BUSY
mechanism),
even though it currently cannot occur.
.PP
Xv6 dedicates a fixed amount of space on the disk to hold the log.
No system call
can be allowed to write more distinct blocks than there is space
in the log. This is not a problem for most system calls, but two
of them can potentially write many blocks: 
.code-index write
and
.code-index unlink .
A large file write may write many data blocks and many bitmap blocks
as well as an inode block; unlinking a large file might write many
bitmap blocks and an inode.
Xv6's write system call breaks up large writes into multiple smaller
writes that fit in the log,
and 
.code unlink
doesn't cause problems because in practice the xv6 file system uses
only one bitmap block.
.\"
.\"
.\"
.section "Code: logging"
.PP
A typical use of the log in a system call looks like this:
.P1
  begin_trans();
  ...
  bp = bread(...);
  bp->data[...] = ...;
  log_write(bp);
  ...
  commit_trans();
.P2
.PP
.code-index begin_trans
.line log.c:/^begin.trans/
waits until it obtains exclusive use of the log and then returns.
.PP
.code-index log_write
.line log.c:/^log.write/
acts as a proxy for 
.code-index bwrite ;
it appends the block's new content to the log on disk and
records the block's sector number in memory.
.code log_write
leaves the modified block in the in-memory buffer cache,
so that subsequent reads of the block during the transaction
will yield the modified block.
.code log_write
notices when a block is written multiple times during a single
transaction, and overwrites the block's previous copy in the log.
.PP
.code-index commit_trans
.line log.c:/^commit.trans/
first writes the log's header block to disk, so that a crash
after this point will cause recovery to re-write the blocks
in the log. 
.code commit_trans
then calls
.code-index install_trans
.line log.c:/^install_trans/
to read each block from the log and write it to the proper
place in the file system.
Finally
.code commit_trans
writes the log header with a count of zero,
so that a crash after the next transaction starts
will result in the recovery code ignoring the log.
.PP
.code-index recover_from_log
.line log.c:/^recover_from_log/
is called from 
.code-index initlog
.line log.c:/^initlog/ ,
which is called during boot before the first user process runs.
.line proc.c:/initlog/
It reads the log header, and mimics the actions of
.code commit_trans
if the header indicates that the log contains a committed transaction.
.PP
An example use of the log occurs in 
.code-index filewrite
.line file.c:/^filewrite/ .
The transaction looks like this:
.P1
      begin_trans();
      ilock(f->ip);
      r = writei(f->ip, ...);
      iunlock(f->ip);
      commit_trans();
.P2
This code is wrapped in a loop that breaks up large writes into individual
transactions of just a few sectors at a time, to avoid overflowing
the log.  The call to
.code-index writei
writes many blocks as part of this
transaction: the file's inode, one or more bitmap blocks, and some data
blocks.
The call to
.code-index ilock
occurs after the
.code-index begin_trans
as part of an overall strategy to avoid deadlock:
since there is effectively a lock around each transaction,
the deadlock-avoiding lock ordering rule is transaction
before inode.
.\"
.\"
.\"
.section "Code: Block allocator"
.PP
File and directory content is stored in disk blocks,
which must be allocated from a free pool.
xv6's block allocator
maintains a free bitmap on disk, with one bit per block. 
A zero bit indicates that the corresponding block is free;
a one bit indicates that it is in use.
The bits corresponding to the boot sector, superblock, inode
blocks, and bitmap blocks are always set.
.PP
The block allocator provides two functions:
.code-index balloc
allocates a new disk block, and
.code-index bfree
frees a block.
.code Balloc
.line fs.c:/^balloc/
starts by calling
.code-index readsb
to read the superblock from the disk (or buffer cache) into
.code sb .
.code balloc
decides which blocks hold the data block free bitmap
by calculating how many blocks are consumed by the
boot sector, the superblock, and the inodes (using 
.code BBLOCK ).
The loop
.line fs.c:/^..for.b.=.0/
considers every block, starting at block 0 up to 
.code sb.size ,
the number of blocks in the file system.
It looks for a block whose bitmap bit is zero,
indicating that it is free.
If
.code balloc
finds such a block, it updates the bitmap 
and returns the block.
For efficiency, the loop is split into two 
pieces.
The outer loop reads each block of bitmap bits.
The inner loop checks all 
.code BPB
bits in a single bitmap block.
The race that might occur if two processes try to allocate
a block at the same time is prevented by the fact that
the buffer cache only lets one process use a block at a time.
.PP
.code Bfree
.line fs.c:/^bfree/
finds the right bitmap block and clears the right bit.
Again the exclusive use implied by
.code bread
and
.code brelse
avoids the need for explicit locking.
.\"
.\" -------------------------------------------
.\"
.section "Inode layer"
.PP
The term 
.italic-index inode 
can have one of two related meanings.
It might refer to the on-disk data structure containing
a file's size and list of data block numbers.
Or ``inode'' might refer to an in-memory inode, which contains
a copy of the on-disk inode as well as extra information needed
within the kernel.
.PP
All of the on-disk inodes
are packed into a contiguous area
of disk called the inode blocks.
Every inode is the same size, so it is easy, given a
number n, to find the nth inode on the disk.
In fact, this number n, called the inode number or i-number,
is how inodes are identified in the implementation.
.PP
The on-disk inode is defined by a
.code-index "struct dinode"
.line fs.h:/^struct.dinode/ .
The 
.code type
field distinguishes between files, directories, and special
files (devices).
A type of zero indicates that an on-disk inode is free.
The
.code nlink
field counts the number of directory entries that
refer to this inode, in order to recognize when the
inode should be freed.
The
.code size
field records the number of bytes of content in the file.
The
.code addrs
array records the block numbers of the disk blocks holding
the file's content.
.PP
The kernel keeps the set of active inodes in memory;
.code-index "struct inode"
.line file.h:/^struct.inode/
is the in-memory copy of a 
.code struct
.code dinode
on disk.
The kernel stores an inode in memory only if there are
C pointers referring to that inode. The
.code ref
field counts the number of C pointers referring to the
in-memory inode, and the kernel discards the inode from
memory if the reference count drops to zero.
The
.code-index iget
and
.code-index iput
functions acquire and release pointers to an inode,
modifying the reference count.
Pointers to an inode can come from file descriptors,
current working directories, and transient kernel code
such as
.code exec .
.PP
Holding a pointer to an inode returned by
.code iget()
guarantees that the inode
will stay in the cache and will not be deleted (and in particular
will not be re-used for a different file). Thus a pointer
returned by
.code iget()
is a weak form of lock, though it does not entitle the holder
to actually look at the inode.
Many parts of the file system code depend on this behavior of
.code iget() ,
both to hold long-term references to inodes (as open files
and current directories) and to prevent races while avoiding
deadlock in code that manipulates multiple inodes (such as
pathname lookup).
.PP
The
.code struct
.code inode
that 
.code iget
returns may not have any useful content.
In order to ensure it holds a copy of the on-disk
inode, code must call
.code-index ilock .
This locks the inode (so that no other process can
.code ilock
it) and reads the inode from the disk,
if it has not already been read.
.code iunlock
releases the lock on the inode.
Separating acquisition of inode pointers from locking
helps avoid deadlock in some situations, for example during
directory lookup.
Multiple processes can hold a C pointer to an inode
returned by 
.code iget ,
but only one process can lock the inode at a time.
.PP
The inode cache only caches inodes to which kernel code
or data structures hold C pointers.
Its main job is really synchronizing access by multiple processes,
not caching.
If an inode is used frequently, the buffer cache will probably
keep it in memory if it isn't kept by the inode cache.
.\"
.\" -------------------------------------------
.\"
.section "Code: Inodes"
.PP
To allocate a new inode (for example, when creating a file),
xv6 calls
.code-index ialloc
.line fs.c:/^ialloc/ .
.code Ialloc
is similar to
.code-index balloc :
it loops over the inode structures on the disk, one block at a time,
looking for one that is marked free.
When it finds one, it claims it by writing the new 
.code type
to the disk and then returns an entry from the inode cache
with the tail call to 
.code-index iget
.line "'fs.c:/return.iget!(dev..inum!)/'" .
The correct operation of
.code ialloc
depends on the fact that only one process at a time
can be holding a reference to 
.code bp :
.code ialloc
can be sure that some other process does not
simultaneously see that the inode is available
and try to claim it.
.PP
.code Iget
.line fs.c:/^iget/
looks through the inode cache for an active entry 
.code ip->ref "" (
.code >
.code 0 )
with the desired device and inode number.
If it finds one, it returns a new reference to that inode.
.lines 'fs.c:/^....if.ip->ref.>.0/,/^....}/' .
As
.code-index iget
scans, it records the position of the first empty slot
.lines fs.c:/^....if.empty.==.0/,/empty.=.ip/ ,
which it uses if it needs to allocate a cache entry.
.PP
Callers must lock the inode using
.code-index ilock
before reading or writing its metadata or content.
.code Ilock
.line fs.c:/^ilock/
uses a now-familiar sleep loop to wait for
.code ip->flag 's
.code-index I_BUSY
bit to be clear and then sets it
.lines 'fs.c:/^..while.ip->flags.&.I_BUSY/,/I_BUSY/' .
Once
.code-index ilock
has exclusive access to the inode, it can load the inode metadata
from the disk (more likely, the buffer cache)
if needed.
The function
.code-index iunlock
.line fs.c:/^iunlock/
clears the
.code-index I_BUSY
bit and wakes any processes sleeping in
.code ilock .
.PP
.code Iput
.line fs.c:/^iput/
releases a C pointer to an inode
by decrementing the reference count
.line 'fs.c:/^..ip->ref--/' .
If this is the last reference, the inode's
slot in the inode cache is now free and can be re-used
for a different inode.
.PP
If 
.code-index iput
sees that there are no C pointer references to an inode
and that the inode has no links to it (occurs in no
directory), then the inode and its data blocks must
be freed.
.code Iput
relocks the inode;
calls
.code-index itrunc
to truncate the file to zero bytes, freeing the data blocks;
sets the inode type to 0 (unallocated);
writes the change to disk;
and finally unlocks the inode
.lines 'fs.c:/ip..ref.==.1/,/^..}/' .
.PP
The locking protocol in 
.code-index iput
deserves a closer look.
The first part worth examining is that when locking
.code ip ,
.code-index iput
simply assumed that it would be unlocked, instead of using a sleep loop.
This must be the case, because the caller is required to unlock
.code ip
before calling
.code iput ,
and
the caller has the only reference to it
.code ip->ref "" (
.code ==
.code 1 ).
The second part worth examining is that
.code iput
temporarily releases
.line fs.c:/^....release/
and reacquires
.line fs.c:/^....acquire/
the cache lock.
This is necessary because
.code-index itrunc
and
.code-index iupdate
will sleep during disk i/o,
but we must consider what might happen while the lock is not held.
Specifically, once 
.code iupdate
finishes, the on-disk structure is marked as available
for use, and a concurrent call to
.code-index ialloc
might find it and reallocate it before 
.code iput
can finish.
.code Ialloc
will return a reference to the block by calling
.code-index iget ,
which will find 
.code ip
in the cache, see that its 
.code-index I_BUSY
flag is set, and sleep.
Now the in-core inode is out of sync compared to the disk:
.code ialloc
reinitialized the disk version but relies on the 
caller to load it into memory during
.code ilock .
In order to make sure that this happens,
.code iput
must clear not only
.code I_BUSY
but also
.code-index I_VALID
before releasing the inode lock.
It does this by zeroing
.code flags
.line 'fs.c:/^....ip->flags.=.0/' .
.\"
.\"
.\"
.section "Code: Inode content"
.figure inode
.PP
The on-disk inode structure,
.code-index "struct dinode" ,
contains a size and an array of block numbers (see 
.figref inode ).
The inode data is found in the blocks listed
in the
.code dinode 's
.code addrs
array.
The first
.code-index NDIRECT
blocks of data are listed in the first
.code NDIRECT
entries in the array; these blocks are called 
.italic-index "direct blocks" .
The next 
.code-index NINDIRECT
blocks of data are listed not in the inode
but in a data block called the
.italic-index "indirect block" .
The last entry in the
.code addrs
array gives the address of the indirect block.
Thus the first 6 kB 
.code NDIRECT \c (
×\c
.code-index BSIZE )
bytes of a file can be loaded from blocks listed in the inode,
while the next
.code 64 kB
.code NINDIRECT \c (
×\c
.code BSIZE )
bytes can only be loaded after consulting the indirect block.
This is a good on-disk representation but a 
complex one for clients.
The function
.code-index bmap
manages the representation so that higher-level routines such as
.code-index readi
and
.code-index writei ,
which we will see shortly.
.code Bmap
returns the disk block number of the
.code bn 'th
data block for the inode
.code ip .
If
.code ip
does not have such a block yet,
.code bmap
allocates one.
.PP
The function
.code-index bmap
.line fs.c:/^bmap/
begins by picking off the easy case: the first 
.code-index NDIRECT
blocks are listed in the inode itself
.lines 'fs.c:/^..if.bn.<.NDIRECT/,/^..}/' .
The next 
.code-index NINDIRECT
blocks are listed in the indirect block at
.code ip->addrs[NDIRECT] .
.code Bmap
reads the indirect block
.line 'fs.c:/bp.=.bread.ip->dev..addr/'
and then reads a block number from the right 
position within the block
.line 'fs.c:/a.=..uint!*.bp->data/' .
If the block number exceeds
.code NDIRECT+NINDIRECT ,
.code bmap 
panics: callers are responsible for not asking about out-of-range block numbers.
.PP
.code Bmap
allocates block as needed.
Unallocated blocks are denoted by a block number of zero.
As
.code bmap
encounters zeros, it replaces them with the numbers of fresh blocks,
allocated on demand.
.line "'fs.c:/^....if..addr.=.*==.0/,/./' 'fs.c:/^....if..addr.*NDIRECT.*==.0/,/./'" .
.PP
.code Bmap
allocates blocks on demand as the inode grows;
.code-index itrunc
frees them, resetting the inode's size to zero.
.code Itrunc
.line fs.c:/^itrunc/
starts by freeing the direct blocks
.lines 'fs.c:/^..for.i.=.0.*NDIRECT/,/^..}/'
and then the ones listed in the indirect block
.lines 'fs.c:/^....for.j.=.0.*NINDIRECT/,/^....}/' ,
and finally the indirect block itself
.lines 'fs.c:/^....bfree.*NDIRECT/,/./' .
.PP
.code Bmap
makes it easy to write functions to access the inode's data stream,
like 
.code-index readi
and
.code-index writei .
.code Readi
.line fs.c:/^readi/
reads data from the inode.
It starts 
making sure that the offset and count are not reading
beyond the end of the file.
Reads that start beyond the end of the file return an error
.lines 'fs.c:/^..if.off.>.ip->size/,/./'
while reads that start at or cross the end of the file 
return fewer bytes than requested
.lines 'fs.c:/^..if.off.!+.n.>.ip->size/,/./' .
The main loop processes each block of the file,
copying data from the buffer into 
.code dst
.lines 'fs.c:/^..for.tot=0/,/^..}/' .
.\" NOTE: It is very hard to write line references
.\" for writei because so many of the lines are identical
.\" to those in readi.  Luckily, identical lines probably
.\" don't need to be commented upon.
The function
.code-index writei
.line fs.c:/^writei/
is identical to
.code-index readi ,
with three exceptions:
writes that start at or cross the end of the file
grow the file, up to the maximum file size
.lines "'fs.c:/^..if.off.!+.n.>.MAXFILE/,/./'" ;
the loop copies data into the buffers instead of out
.line 'fs.c:/memmove.bp->data/' ;
and if the write has extended the file,
.code-index writei
must update its size
.line "'fs.c:/^..if.n.>.0.*off.>.ip->size/,/^..}/'" .
.PP
Both
.code-index readi
and
.code-index writei
begin by checking for
.code ip->type
.code ==
.code-index T_DEV .
This case handles special devices whose data does not
live in the file system; we will return to this case in the file descriptor layer.
.PP
The function
.code-index stati
.line fs.c:/^stati/
copies inode metadata into the 
.code stat
structure, which is exposed to user programs
via the
.code-index stat
system call.
.\"
.\"
.\"
.section "Code: directory layer"
.PP
A directory is implemented internally much like a file.
Its inode has type
.code-index T_DIR
and its data is a sequence of directory entries.
Each entry is a
.code-index "struct dirent"
.line fs.h:/^struct.dirent/ ,
which contains a name and an inode number.
The name is at most
.code-index DIRSIZ
(14) characters;
if shorter, it is terminated by a NUL (0) byte.
Directory entries with inode number zero are free.
.PP
The function
.code-index dirlookup
.line fs.c:/^dirlookup/
searches a directory for an entry with the given name.
If it finds one, it returns a pointer to the corresponding inode, unlocked,
and sets 
.code *poff
to the byte offset of the entry within the directory,
in case the caller wishes to edit it.
If
.code dirlookup
finds an entry with the right name,
it updates
.code *poff ,
releases the block, and returns an unlocked inode
obtained via
.code-index iget .
.code Dirlookup
is the reason that 
.code iget
returns unlocked inodes.
The caller has locked
.code dp ,
so if the lookup was for
.code-index "." ,
an alias for the current directory,
attempting to lock the inode before
returning would try to re-lock
.code dp
and deadlock.
(There are more complicated deadlock scenarios involving
multiple processes and
.code-index ".." ,
an alias for the parent directory;
.code "."
is not the only problem.)
The caller can unlock
.code dp
and then lock
.code ip ,
ensuring that it only holds one lock at a time.
.PP
The function
.code-index dirlink
.line fs.c:/^dirlink/
writes a new directory entry with the given name and inode number into the
directory
.code dp .
If the name already exists,
.code dirlink
returns an error
.lines 'fs.c:/Check.that.name.is.not.present/,/^..}/' .
The main loop reads directory entries looking for an unallocated entry.
When it finds one, it stops the loop early
.lines 'fs.c:/^....if.de.inum.==.0/,/./' ,
with 
.code off
set to the offset of the available entry.
Otherwise, the loop ends with
.code off
set to
.code dp->size .
Either way, 
.code dirlink
then adds a new entry to the directory
by writing at offset
.code off
.lines 'fs.c:/^..strncpy/,/panic/' .
.\"
.\"
.\"
.section "Code: Path names"
.PP
Path name lookup involves a succession of calls to
.code-index dirlookup ,
one for each path component.
.code Namei
.line fs.c:/^namei/
evaluates 
.code path
and returns the corresponding 
.code inode .
The function
.code-index nameiparent
is a variant: it stops before the last element, returning the 
inode of the parent directory and copying the final element into
.code name .
Both call the generalized function
.code-index namex
to do the real work.
.PP
.code Namex
.line fs.c:/^namex/
starts by deciding where the path evaluation begins.
If the path begins with a slash, evaluation begins at the root;
otherwise, the current directory
.line "'fs.c:/..if.!*path.==....!)/,/idup/'" .
Then it uses
.code-index skipelem
to consider each element of the path in turn
.line fs.c:/while.*skipelem/ .
Each iteration of the loop must look up 
.code name
in the current inode
.code ip .
The iteration begins by locking
.code ip
and checking that it is a directory.
If not, the lookup fails
.lines fs.c:/^....ilock.ip/,/^....}/ .
(Locking
.code ip
is necessary not because 
.code ip->type
can change underfoot—it can't—but because
until 
.code-index ilock
runs,
.code ip->type
is not guaranteed to have been loaded from disk.)
If the call is 
.code-index nameiparent
and this is the last path element, the loop stops early,
as per the definition of
.code nameiparent ;
the final path element has already been copied
into
.code name ,
so
.code-index namex
need only
return the unlocked
.code ip
.lines fs.c:/^....if.nameiparent/,/^....}/ .
Finally, the loop looks for the path element using
.code-index dirlookup
and prepares for the next iteration by setting
.code "ip = next"
.lines 'fs.c:/^....if..next.*dirlookup/,/^....ip.=.next/' .
When the loop runs out of path elements, it returns
.code ip .
.\"
.\"
.\"
.section "File descriptor layer"
.PP
One of the cool aspect of the Unix interface is that most resources in Unix are
represented as a file, including devices such as the console, pipes, and of
course, real files.  The file descriptor layer is the layer that achieves this
uniformity.
.PP
Xv6 gives each process its own table of open files, or
file descriptors, as we saw in
Chapter \*[CH:UNIX].
Each open file is represented by a
.code-index "struct file"
.line file.h:/^struct.file/ ,
which is a wrapper around either an inode or a pipe,
plus an i/o offset.
Each call to 
.code-index open
creates a new open file (a new
.code struct
.code file ):
if multiple processes open the same file independently,
the different instances will have different i/o offsets.
On the other hand, a single open file
(the same
.code struct
.code file )
can appear
multiple times in one process's file table
and also in the file tables of multiple processes.
This would happen if one process used
.code open
to open the file and then created aliases using
.code-index dup
or shared it with a child using
.code-index fork .
A reference count tracks the number of references to
a particular open file.
A file can be open for reading or writing or both.
The
.code readable
and
.code writable
fields track this.
.PP
All the open files in the system are kept in a global file table,
the 
.code-index ftable .
The file table
has a function to allocate a file
.code-index filealloc ), (
create a duplicate reference
.code-index filedup ), (
release a reference
.code-index fileclose ), (
and read and write data
.code-index fileread "" (
and 
.code-index filewrite ).
.PP
The first three follow the now-familiar form.
.code Filealloc
.line file.c:/^filealloc/
scans the file table for an unreferenced file
.code f->ref "" (
.code ==
.code 0 )
and returns a new reference;
.code-index filedup
.line file.c:/^filedup/
increments the reference count;
and
.code-index fileclose
.line file.c:/^fileclose/
decrements it.
When a file's reference count reaches zero,
.code fileclose
releases the underlying pipe or inode,
according to the type.
.PP
The functions
.code-index filestat ,
.code-index fileread ,
and
.code-index filewrite
implement the 
.code-index stat ,
.code-index read ,
and
.code-index write
operations on files.
.code Filestat
.line file.c:/^filestat/
is only allowed on inodes and calls
.code-index stati .
.code Fileread
and
.code filewrite
check that the operation is allowed by
the open mode and then
pass the call through to either
the pipe or inode implementation.
If the file represents an inode,
.code fileread
and
.code filewrite
use the i/o offset as the offset for the operation
and then advance it
.lines "'file.c:/readi/,/./' 'file.c:/writei/,/./'" .
Pipes have no concept of offset.
Recall that the inode functions require the caller
to handle locking
.lines "'file.c:/stati/-1,/iunlock/' 'file.c:/readi/-1,/iunlock/' 'file.c:/writei/-1,/iunlock/'" .
The inode locking has the convenient side effect that the
read and write offsets are updated atomically, so that
multiple writing to the same file simultaneously
cannot overwrite each other's data, though their writes may end up interlaced.
.\"
.\"
.\"
.section "Code: System calls"
.PP
With the functions that the lower layers provide the implementation of most
system calls is trivial (see
.file sysfile.c  ). 
There are a few calls that
deserve a closer look.
.PP
The functions
.code-index sys_link
and
.code-index sys_unlink
edit directories, creating or removing references to inodes.
They are another good example of the power of using 
transactions. 
.code Sys_link
.line sysfile.c:/^sys_link/
begins by fetching its arguments, two strings
.code old
and
.code new
.line sysfile.c:/argstr.*old.*new/ .
Assuming 
.code old
exists and is not  a directory
.lines sysfile.c:/namei.old/,/^..}/ ,
.code sys_link
increments its 
.code ip->nlink
count.
Then
.code sys_link
calls
.code-index nameiparent
to find the parent directory and final path element of
.code new 
.line sysfile.c:/nameiparent.new/
and creates a new directory entry pointing at
.code old 's
inode
.line "'sysfile.c:/!|!| dirlink/'" .
The new parent directory must exist and
be on the same device as the existing inode:
inode numbers only have a unique meaning on a single disk.
If an error like this occurs, 
.code-index sys_link
must go back and decrement
.code ip->nlink .
.PP
Transactions simplify the implementation because it requires updating multiple
disk blocks, but we don't have to worry about the order in which we do
them. They either will all succeed or none.
For example, without transactions, updating
.code ip->nlink
before creating a link, would put the file system temporarily in an unsafe
state, and a crash in between could result in havoc.
With transactions we don't have to worry about this.
.PP
.code Sys_link
creates a new name for an existing inode.
The function
.code-index create
.line sysfile.c:/^create/
creates a new name for a new inode.
It is a generalization of the three file creation
system calls:
.code-index open
with the
.code-index O_CREATE
flag makes a new ordinary file,
.code-index mkdir
makes a new directoryy,
and
.code-index mkdev
makes a new device file.
Like
.code-index sys_link ,
.code-index create
starts by caling
.code-index nameiparent
to get the inode of the parent directory.
It then calls
.code-index dirlookup
to check whether the name already exists
.line 'sysfile.c:/dirlookup.*[^=]=.0/' .
If the name does exist, 
.code create 's
behavior depends on which system call it is being used for:
.code open
has different semantics from 
.code-index mkdir
and
.code-index mkdev .
If
.code create
is being used on behalf of
.code open
.code type "" (
.code ==
.code-index T_FILE )
and the name that exists is itself
a regular file,
then 
.code open
treats that as a success,
so
.code create
does too
.line "sysfile.c:/^......return.ip/" .
Otherwise, it is an error
.lines sysfile.c:/^......return.ip/+1,/return.0/ .
If the name does not already exist,
.code create
now allocates a new inode with
.code-index ialloc
.line sysfile.c:/ialloc/ .
If the new inode is a directory, 
.code create
initializes it with
.code-index .
and
.code-index ..
entries.
Finally, now that the data is initialized properly,
.code-index create
can link it into the parent directory
.line sysfile.c:/if.dirlink/ .
.code Create ,
like
.code-index sys_link ,
holds two inode locks simultaneously:
.code ip
and
.code dp .
There is no possibility of deadlock because
the inode
.code ip
is freshly allocated: no other process in the system
will hold 
.code ip 's
lock and then try to lock
.code dp .
.PP
Using
.code create ,
it is easy to implement
.code-index sys_open ,
.code-index sys_mkdir ,
and
.code-index sys_mknod .
.code Sys_open
.line sysfile.c:/^sys_open/
is the most complex, because creating a new file is only
a small part of what it can do.
If
.code-index open
is passed the
.code-index O_CREATE
flag, it calls
.code create
.line sysfile.c:/create.*T_FILE/ .
Otherwise, it calls
.code-index namei
.line sysfile.c:/if..ip.=.namei.path/ .
.code Create
returns a locked inode, but 
.code namei
does not, so
.code-index sys_open
must lock the inode itself.
This provides a convenient place to check that directories
are only opened for reading, not writing.
Assuming the inode was obtained one way or the other,
.code sys_open
allocates a file and a file descriptor
.line sysfile.c:/filealloc.*fdalloc/
and then fills in the file
.lines sysfile.c:/type.=.FD_INODE/,/writable/ .
Note that no other process can access the partially initialized file since it is only
in the current process's table.
.PP
Chapter \*[CH:SCHED] examined the implementation of pipes
before we even had a file system.
The function
.code-index sys_pipe
connects that implementation to the file system
by providing a way to create a pipe pair.
Its argument is a pointer to space for two integers,
where it will record the two new file descriptors.
Then it allocates the pipe and installs the file descriptors.
.\"
.\" -------------------------------------------
.\"
.section "Real world"
.PP
The buffer cache in a real-world operating system is significantly
more complex than xv6's, but it serves the same two purposes:
caching and synchronizing access to the disk.
Xv6's buffer cache, like V6's, uses a simple least recently used (LRU)
eviction policy; there are many more complex
policies that can be implemented, each good for some
workloads and not as good for others.
A more efficient LRU cache would eliminate the linked list,
instead using a hash table for lookups and a heap for LRU evictions.
Modern buffer caches are typically integrated with the
virtual memory system to support memory-mapped files.
.PP
Xv6's logging system is woefully inefficient. It does not allow concurrent
updating system calls, even when the system calls operate on entirely
different parts of the file system. It logs entire blocks, even if
only a few bytes in a block are changed. It performs synchronous
log writes, a block at a time, each of which is likely to require an
entire disk rotation time. Real logging systems address all of these
problems.
.PP
Logging is not the only way to provide crash recovery. Early file systems
used a scavenger during reboot (for example, the UNIX
.code-index fsck
program) to examine every file and directory and the block and inode
free lists, looking for and resolving inconsistencies. Scavenging can take
hours for large file systems, and there are situations where it is not
possible to resolve inconsistencies in a way that causes the original
system calls to be atomic. Recovery
from a log is much faster and causes system calls to be atomic
in the face of crashes.
.PP
Xv6 uses the same basic on-disk layout of inodes and directories
as early UNIX;
this scheme has been remarkably persistent over the years.
BSD's UFS/FFS and Linux's ext2/ext3 use essentially the same data structures.
The most inefficient part of the file system layout is the directory,
which requires a linear scan over all the disk blocks during each lookup.
This is reasonable when directories are only a few disk blocks,
but is expensive for directories holding many files.
Microsoft Windows's NTFS, Mac OS X's HFS, and Solaris's ZFS, just to name a few, implement
a directory as an on-disk balanced tree of blocks.
This is complicated but guarantees logarithmic-time directory lookups.
.PP
Xv6 is naive about disk failures: if a disk
operation fails, xv6 panics.
Whether this is reasonable depends on the hardware:
if an operating systems sits atop special hardware that uses
redundancy to mask disk failures, perhaps the operating system
sees failures so infrequently that panicking is okay.
On the other hand, operating systems using plain disks
should expect failures and handle them more gracefully,
so that the loss of a block in one file doesn't affect the
use of the rest of the file system.
.PP
Xv6 requires that the file system
fit on one disk device and not change in size.
As large databases and multimedia files drive storage
requirements ever higher, operating systems are developing ways
to eliminate the ``one disk per file system'' bottleneck.
The basic approach is to combine many disks into a single
logical disk.  Hardware solutions such as RAID are still the 
most popular, but the current trend is moving toward implementing
as much of this logic in software as possible.
These software implementations typically 
allow rich functionality like growing or shrinking the logical
device by adding or removing disks on the fly.
Of course, a storage layer that can grow or shrink on the fly
requires a file system that can do the same: the fixed-size array
of inode blocks used by xv6 would not work well
in such environments.
Separating disk management from the file system may be
the cleanest design, but the complex interface between the two
has led some systems, like Sun's ZFS, to combine them.
.PP
Xv6's file system lacks many other features of modern file systems; for example,
it lacks support for snapshots and incremental backup.
.PP
Modern Unix systems allow many kinds of resources to be
accessed with the same system calls as on-disk storage:
named pipes, network connections,
remotely-accessed network file systems, and monitoring and control
interfaces such as
.code /proc .
Instead of xv6's
.code if
statements in
.code-index fileread
and
.code-index filewrite ,
these systems typically give each open file a table of function pointers,
one per operation,
and call the function pointer to invoke that inode's
implementation of the call.
Network file systems and user-level file systems 
provide functions that turn those calls into network RPCs
and wait for the response before returning.
.\"
.\" -------------------------------------------
.\"
.section "Exercises"
.PP
1. why panic in balloc?  Can we recover?
.PP
2. why panic in ialloc?  Can we recover?
.PP
3. inode generation numbers.
.PP
4. Why doesn't filealloc panic when it runs out of files?
Why is this more common and therefore worth handling?
.PP
5. Suppose the file corresponding to 
.code ip
gets unlinked by another process
between 
.code sys_link 's
calls to 
.code iunlock(ip)
and
.code dirlink .
Will the link be created correctly?
Why or why not?
.PP
6.
.code create
makes four function calls (one to
.code ialloc
and three to
.code dirlink )
that it requires to succeed.
If any doesn't,
.code create
calls
.code panic .
Why is this acceptable?
Why can't any of those four calls fail?
.PP
7. 
.code sys_chdir
calls
.code iunlock(ip)
before
.code iput(cp->cwd) ,
which might try to lock
.code cp->cwd ,
yet postponing
.code iunlock(ip)
until after the
.code iput
would not cause deadlocks.
Why not?

