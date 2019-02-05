echo "****************************************************"
echo "****************************************************"
echo ""
echo "Sitara Example Flashing Script - 02/11/2014"
echo ""

STARTTIME=$(date +%s)

##---------Start of variables---------------------##

## Set Server IP here
SERVER_IP=$1

## Names of the images to grab from TFTP server
BOOT_PARTITION="P032_Bootloader.tar.gz"

## Rename rootfs as needed depending on use of tar or img
ROOTFS_PARTITION="P032_Platform.tar.gz"

## Birth certificate
BIRTH_CERTIFICATE="Birth_Certificate.tar.gz"

## Declare eMMC device name here
DRIVE="/dev/mmcblk0"

#echo "resetting flash..." > /dev/kmsg
#time tr '\0' '\377' < /dev/zero > $DRIVE
#sync
#echo "finished resetting flash..." > /dev/kmsg

##----------End of variables-----------------------##

network_ifs="usb0 eth0"
selected_net_if=""
unit_ip=""

## Bring up the USB interface. CPSW Ethernet is automatically brought up
## by init scripts.
for cur_if in ${network_ifs}; do
  echo "Checking for Ip Address on $cur_if.." > /dev/kmsg
  ifup $cur_if
  sleep 3
  unit_ip=`ifconfig $cur_if | awk '/inet addr/{print substr($2,6)}'`
  if [ ! -z "${unit_ip}" ]; then
    selected_net_if="${cur_if}"
    break
  fi
done
echo "using $selected_net_if : $unit_ip" > /dev/kmsg

time tftp -g -r ${BIRTH_CERTIFICATE} ${SERVER_IP} &
birth_pid=$!

## Check to see if the eMMC partitions have automatically loaded from the old MBR.
## This might have occured during the boot process if the kernel detected a filesystem
## before we killed the MBR. We will need to unmount and kill them by writing 4k zeros to the
## partitions that were found.

check_mounted(){
  is_mounted=$(grep ${DRIVE}p /proc/mounts | awk '{print $2}')

  if grep -q ${DRIVE}p /proc/mounts; then
      echo "Found mounted partition(s) on " ${DRIVE}": " $is_mounted > /dev/kmsg
      umount $is_mounted
      counter=1
      for i in $is_mounted; do \
	  if [ $counter != 4 ]; then
	      echo "4k erase on ${DRIVE}p${counter}" > /dev/kmsg
	      dd if=/dev/zero of=${DRIVE}p${counter} bs=4k count=1;
	  fi
	  counter=$((counter+1));
      done
  else
      echo "No mounted partition found. Continuing." > /dev/kmsg
  fi
}

check_mounted;

COMPLETION_MSG="FAIL"
# Download the full flash image if available
FLASH_IMAGE="ipu_flash.img"
BOOT0_IMAGE="boot0.img"
BOOT1_IMAGE="boot1.img"

#Enable LEDs
echo 50 > /sys/class/gpio/export 2>/dev/null
echo out > /sys/class/gpio/gpio50/direction
echo 1 > /sys/class/gpio/gpio50/value

echo "Please insert the pendrive with the $FLASH_IMAGE file under root, waiting for 30s" > /dev/kmsg
pendrive_timeout=30
pendrive_device="/dev/sda1"
pendrive_path="pendrive"
full_image_programmed=0
while [ $pendrive_timeout -gt 0 ]; do
	if [ -e $pendrive_device ]; then
		echo ""
		echo "Found $pendrive_device" > /dev/kmsg
		pendrive_timeout=0
		mkdir -p $pendrive_path
		mount $pendrive_device $pendrive_path
		if [ $? -eq 0 ] && [ -d $pendrive_path ]; then
			cd $pendrive_path
			# left the second check in place for ease if we ever need to add more files to check
			if [ -f $FLASH_IMAGE ] && [ -f $FLASH_IMAGE ]; then
				echo "Found $FLASH_IMAGE. Programming might take a while" > /dev/kmsg
				echo "dd if=$FLASH_IMAGE of=$DRIVE bs=1M" > /dev/kmsg
				time dd if=$FLASH_IMAGE of=$DRIVE bs=1M > /dev/kmsg
				#time dd if=$FLASH_IMAGE of=/dev/null bs=1M > /dev/kmsg

				if [ -r "$BOOT1_IMAGE" ]; then
					echo 0 > /sys/block/mmcblk0boot1/force_ro
					echo "dd if=$BOOT1_IMAGE of=${DRIVE}boot1 bs=1M" > /dev/kmsg
					dd if=$BOOT1_IMAGE of=${DRIVE}boot1 bs=1M >> /dev/null 2>&1
					echo 1 > /sys/block/mmcblk0boot1/force_ro
				else
					echo "no $BOOT1_IMAGE is found, skipping..."
				fi
				
				if [ -r "$BOOT0_IMAGE" ]; then
					echo 0 > /sys/block/mmcblk0boot0/force_ro
					echo "dd if=$BOOT0_IMAGE of=${DRIVE}boot0 bs=1M" > /dev/kmsg
					dd if=$BOOT0_IMAGE of=${DRIVE}boot0 bs=1M >> /dev/null 2>&1
					sync
					echo 1 > /sys/block/mmcblk0boot0/force_ro
				else
					echo "no $BOOT0_IMAGE is found, skipping..."
				fi

				printf "Calculating $DRIVE md5sum: " > /dev/kmsg
				disk_md5=`md5sum $DRIVE | cut -d" " -f1`
				echo "$disk_md5" > /dev/kmsg

				#printf "Calculating $FLASH_IMAGE md5sum: " > /dev/kmsg
				#file_md5=`md5sum $FLASH_IMAGE | cut -d" " -f1`
				#echo "$file_md5" > /dev/kmsg

				COMPLETION_MSG="SUCCESS"
			else
				echo "Missing one or more of the following files: $FLASH_IMAGE" > /dev/kmsg
			fi
			cd ..
			umount $pendrive_path
		fi
		rm -rf $pendrive_path

		if [ "$COMPLETION_MSG" != "SUCCESS" ]; then
			echo "[FAIL]: Burning full flash image failed, please wait..." > /dev/kmsg

			# make sure that the partition table is wiped off, so, we can recover via uniflash
			# a healthy partition table without any actual content to boot bricks the unit
			dd if=/dev/zero of=$DRIVE bs=1024 count=1024
			echo "[FAIL]: Cleared the partition table, you might be able to recover by using an older sw via uniflash" > /dev/kmsg
			echo "Continuing with tftp download..." > /dev/kmsg
		fi

		break;
	fi
	pendrive_timeout=$((pendrive_timeout-1));
	printf "." > /dev/kmsg
	sleep 1;
done

# Check if the flash image download attempt was successful
if [ "$COMPLETION_MSG" != "SUCCESS" ]; then
	echo ""
	## Make temp directories for mountpoints
	mkdir -p tmp_boot

	## Comment this line out if using 'dd' of an image. It is not needed.
	mkdir -p tmp_rootfs1 tmp_rootfs2 tmp_rootfs3

	## TFTP files from host.  Edit the files and host IP address for your application.
	## We are grabbing two files, one an archive with files to populate a FAT partion,
	## which we will create.  Another for a filesystem image to 'dd' onto an unmounted partition.
	## Using a compressed tarball can be easier to implement, however, with a large file system
	## with a lot of small files, we recommend a 'dd' image of the partition to speed up writes.
	echo "Getting files from server: ${SERVER_IP}" > /dev/kmsg
	time tftp -g -r ${BOOT_PARTITION} ${SERVER_IP} &
	boot_pid=$!
	time tftp -g -r ${ROOTFS_PARTITION} ${SERVER_IP} &
	rootfs_pid=$!

	## Kill any partition info that might be there
	dd if=/dev/zero of=$DRIVE bs=1024 count=1024
	exit_code=$?
	sync

	## Figure out how big the eMMC is in bytes
	SIZE=`fdisk -l $DRIVE | grep Disk | awk '{print $5}'`

	## Translate size into segments, which traditional tools call Cylinders. eMMC is not a spinning disk.
	## We are basically ignoring what FDISK and SFDISK are reporting because it is not really accurate.
	## we are translating this info to something that makes more sense for eMMC.
	CYLINDERS=`echo $SIZE/255/63/512 | bc`

	## Partitioning the eMMC using information gathered.
	## Here is where you can add/remove partitions.
	## We are building 2 partitions:
	##  1. FAT, size = 9 cylinders * 255 heads * 63 sectors * 512 bytes/sec = ~70MB
	##  2. EXT3, size = 223 ($CYLINDERS-[9 for fat]) cylinders * 255 heads * 63 sectors * 512 bytes/sec = ~1.7GB
	##
	## You will need to change the lines ",9,0c0C,*", "10,,,-" to suit your needs.  Adding is similar,
	## but you will need to be aware of partition sizes and boundaries.  Use the man page for sfdisk.

	echo "Partitioning the eMMC into 6 partitions..." > /dev/kmsg

	#Create the partitions
	sfdisk -D -H 255 -S 63 -C $CYLINDERS $DRIVE << EOF
,1,0x0C,*
,32
,32
,,E
,32
,32
;
EOF

	exit_code=$((exit_code+$?))
	## This sleep is necessary as there is a service which attempts
	## to automount any filesystems that it finds as soon as sfdisk
	## finishes partitioning.  We sleep to let it run.  May need to
	## be lengthened if you have more partitions.
	sleep 2

	blockdev --rereadpt /dev/mmcblk0 > /dev/kmsg

	## Check here if there has been a partition that automounted.
	##  This will eliminate the old partition that gets
	##  automatically found after the sfdisk command.  It ONLY
	##  gets found if there was a previous file system on the same
	##  partition boundary.  Happens when running this script more than once.
	##  To fix, we just unmount and write some zeros to it.
	check_mounted;

	## Format the eMMC into partitions
	echo "Formatting the eMMC partitions..." > /dev/kmsg

	## Format the boot partition of type fat
	umount ${DRIVE}p1 >> /dev/null 2>&1
	mkfs.vfat -n "BOOT" ${DRIVE}p1
	exit_code=$((exit_code+$?))
	echo "Formatted boot" > /dev/kmsg
	umount ${DRIVE}p1 >> /dev/null 2>&1

	## Format the rootfs to ext3 (or ext4, etc.) if using a tar file.
	## We DO NOT need to format this partition if we are 'dd'ing an image
	## Comment out this line if using 'dd' of an image.

	umount ${DRIVE}p2 >> /dev/null 2>&1
	mke2fs -t ext4 -J size=1 -L "primary" ${DRIVE}p2
	exit_code=$((exit_code+$?))
	echo "Formatted primary" > /dev/kmsg

	umount ${DRIVE}p3 >> /dev/null 2>&1
	mke2fs -t ext4 -J size=1 -L "backup1" ${DRIVE}p3
	exit_code=$((exit_code+$?))
	echo "Formatted backup1" > /dev/kmsg

	umount ${DRIVE}p5 >> /dev/null 2>&1
	mke2fs -t ext4 -J size=1 -L "backup2" ${DRIVE}p5
	exit_code=$((exit_code+$?))
	echo "Formatted backup2" > /dev/kmsg

	umount ${DRIVE}p6 >> /dev/null 2>&1
	mke2fs -t ext4 -J size=1 -L "temp part" ${DRIVE}p6
	exit_code=$((exit_code+$?))
	echo "Formatted temp part" > /dev/kmsg

	umount ${DRIVE}p7 >> /dev/null 2>&1
	mke2fs -t ext4 -J size=256 -L "user data" ${DRIVE}p7
	exit_code=$((exit_code+$?))
	echo "Formatted user data" > /dev/kmsg

	## Make sure posted writes are cleaned up
	#sync
	echo "Formatting done." > /dev/kmsg

	## Mount partitions for tarball extraction. NOT for 'dd'.
	mount -t vfat ${DRIVE}p1 tmp_boot
	exit_code=$((exit_code+$?))

	## If 'dd'ing the rootfs, there is no need to mount it. Comment out the below.
	mount -t ext4 ${DRIVE}p2 tmp_rootfs1
	exit_code=$((exit_code+$?))
	mount -t ext4 ${DRIVE}p3 tmp_rootfs2
	exit_code=$((exit_code+$?))
	mount -t ext4 ${DRIVE}p5 tmp_rootfs3
	exit_code=$((exit_code+$?))

	if [ $exit_code -ne 0 ]; then
		echo "[FAIL]: Partition creation, exit code: $exit_code, please wait..." > /dev/kmsg

		# make sure that the partition table is wiped off, so, we can recover via uniflash
		# a healthy partition table without any actual content to boot bricks the unit
		dd if=/dev/zero of=$DRIVE bs=1024 count=1024
		echo "[FAIL]: Cleared the partition table, you might be able to recover by using an older sw via uniflash" > /dev/kmsg
		exit -1
	fi

	## Wait for boot to finish tftp
	echo "Waiting for Boot Files copy to finish..." > /dev/kmsg
	wait $boot_pid
	echo "Untarring Boot Files..." > /dev/kmsg
	time tar -xzf ${BOOT_PARTITION} -C tmp_boot
	exit_code=$((exit_code+$?))
	chown -R root:root tmp_boot >> /dev/null 2>&1
	sync
	umount ${DRIVE}p1 >> /dev/null 2>&1
	echo "Boot partition done." > /dev/kmsg

	if [ $exit_code -ne 0 ]; then
		echo "[FAIL]: Boot untarring, exit code: $exit_code, please wait..." > /dev/kmsg

		# make sure that the partition table is wiped off, so, we can recover via uniflash
		# a healthy partition table without any actual content to boot bricks the unit
		dd if=/dev/zero of=$DRIVE bs=1024 count=1024
		echo "[FAIL]: Cleared the partition table, you might be able to recover by using an older sw via uniflash" > /dev/kmsg
		exit -1
	fi

	## Wait for rootfs to finish tftp
	echo "Waiting for Rootfs Files copy to finish..." > /dev/kmsg
	wait $rootfs_pid
	echo "Untarring Rootfs Files to ${DRIVE}p2..." > /dev/kmsg
	## If using a tar archive, untar it with the below.
	## If using 'dd' of an img, comment these lines out and use the below.
	time tar -xzf ${ROOTFS_PARTITION} -C tmp_rootfs1
	exit_code=$((exit_code+$?))
	chown -R root:root tmp_rootfs1 >> /dev/null 2>&1
	sync
	umount ${DRIVE}p2
	echo "Done" > /dev/kmsg

	echo "Untarring Rootfs Files to ${DRIVE}p3..." > /dev/kmsg
	time tar -xzf ${ROOTFS_PARTITION} -C tmp_rootfs2
	exit_code=$((exit_code+$?))
	chown -R root:root tmp_rootfs2 >> /dev/null 2>&1
	sync
	umount ${DRIVE}p3
	echo "Done" > /dev/kmsg

	echo "Untarring Rootfs Files to ${DRIVE}p5..." > /dev/kmsg
	time tar -xzf ${ROOTFS_PARTITION} -C tmp_rootfs3
	exit_code=$((exit_code+$?))
	chown -R root:root tmp_rootfs3 >> /dev/null 2>&1
	sync
	umount ${DRIVE}p5
	echo "Done" > /dev/kmsg

	#Delete u-boot env
	echo "Deleting the u-boot env area" > /dev/kmsg
	echo 0 > /sys/block/mmcblk0boot1/force_ro
	dd if=/dev/zero of=${DRIVE}boot1 >> /dev/null 2>&1 #bs=1024 count=10
	sync
	echo 1 > /sys/block/mmcblk0boot1/force_ro

	# Disable hardware protection
	echo "Programming the Birth certificate" > /dev/kmsg
	echo 0 > /sys/block/mmcblk0boot0/force_ro
	umount ${DRIVE}boot0 >> /dev/null 2>&1
	mke2fs -t ext4 -J size=1 -L "config" ${DRIVE}boot0
	exit_code=$((exit_code+$?))
	mkdir -p tmp_config
	mount -t ext4 ${DRIVE}boot0 tmp_config
	exit_code=$((exit_code+$?))

	## Wait for birth to finish tftp
	wait $birth_pid
	time tar -xzf ${BIRTH_CERTIFICATE} -C tmp_config
	exit_code=$((exit_code+$?))
	umount ${DRIVE}boot0 >> /dev/null 2>&1
	echo 1 > /sys/block/mmcblk0boot0/force_ro

	echo "Birth certificate done." > /dev/kmsg

	if [ $exit_code -ne 0 ]; then
		echo "[FAIL]: Rootfs untarring, exit code: $exit_code, you should have a healthy partition table and bootloader, you might be able to recover by using an older sw via uniflash" > /dev/kmsg
		exit -1
	fi

	sync
	sync

	echo "Verifying the flashed partitions" > /dev/kmsg

	#re mount the partitions
	mount -t vfat ${DRIVE}p1 tmp_boot
	mount -t ext4 ${DRIVE}p2 tmp_rootfs1
	mount -t ext4 ${DRIVE}p3 tmp_rootfs2
	mount -t ext4 ${DRIVE}p5 tmp_rootfs3

	BOOT_SIZE=300
	ROOTFS_SIZE=100
	COUNTER=1

	bootsize=`du -sh  tmp_boot | awk '{print $1}' | cut -d . -f1`

	echo "Minimum expected Rootfs size : $ROOTFS_SIZE and boot part size : $BOOT_SIZE" > /dev/kmsg

	COMPLETION_MSG="SUCCESS"
	while [ $COUNTER -lt 4 ]
	do
	  echo " The tmp_rootfs${COUNTER}" > /dev/kmsg
	  rootsize=`du -sh tmp_rootfs${COUNTER} | awk '{print $1}' | cut -d . -f1`
	  echo "The calculated rootfs${COUNTER} size : $rootsize and boot part size : $bootsize" > /dev/kmsg
	  if ([ "$rootsize" \> "$ROOTFS_SIZE" ] && [ "$bootsize" \> "$BOOT_SIZE" ])
	  then
	    echo "Verifying ...." > /dev/kmsg
	  else
	    echo "Verification failed, RGB1 RGB2 Red LED ...." > /dev/kmsg
	    dd if=/dev/zero of=$DRIVE bs=1024 count=1024
	    echo "[FAIL]: Cleared the partition table, you might be able to recover by using an older sw via uniflash" > /dev/kmsg
	    COMPLETION_MSG="FAIL"
	    echo 0 > /sys/class/leds/RGB1_cntr0/brightness
	    echo 0 > /sys/class/leds/RGB2_cntr0/brightness
	    echo 0 > /sys/class/leds/RGB1_cntr1/brightness
	    echo 0 > /sys/class/leds/RGB2_cntr1/brightness
	    echo 1 > /sys/class/leds/RGB1_cntr2/brightness
	    echo 1 > /sys/class/leds/RGB2_cntr2/brightness
	    break
	  fi
	  COUNTER=$[$COUNTER + 1]
	done

	umount ${DRIVE}p1
	umount ${DRIVE}p2
	umount ${DRIVE}p3
	umount ${DRIVE}p5
	sync

fi

if [ "$COMPLETION_MSG" == "SUCCESS" ]; then
	echo "[SUCCESS]: RGB1 RGB2 Green LED ...." > /dev/kmsg
	echo 0 > /sys/class/leds/RGB1_cntr1/brightness
	echo 0 > /sys/class/leds/RGB2_cntr1/brightness
	echo 0 > /sys/class/leds/RGB1_cntr2/brightness
	echo 0 > /sys/class/leds/RGB2_cntr2/brightness
	echo 1 > /sys/class/leds/RGB1_cntr0/brightness
	echo 1 > /sys/class/leds/RGB2_cntr0/brightness
fi

ENDTIME=$(date +%s)
echo "It took $(($ENDTIME - $STARTTIME)) seconds to complete this task..." > /dev/kmsg
## Reboot
echo "" > /dev/kmsg
echo "********************************************" > /dev/kmsg
echo "[$COMPLETION_MSG]: Sitara Example Flash Script is complete." > /dev/kmsg
echo "" > /dev/kmsg

exit 0
