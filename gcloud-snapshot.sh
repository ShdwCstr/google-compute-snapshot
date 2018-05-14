#!/usr/bin/env bash
export PATH=$PATH:/usr/local/bin/:/usr/bin




###############################
##                           ##
## INITIATE SCRIPT FUNCTIONS ##
##                           ##
##  FUNCTIONS ARE EXECUTED   ##
##   AT BOTTOM OF SCRIPT     ##
##                           ##
###############################


#
# DOCUMENTS ARGUMENTS
#

usage() {
  echo -e "\nUsage: $0 [-d <days>] [-p <prefix>]" 1>&2
  echo -e "\nOptions:\n"
  echo -e "    -d    Number of days to keep snapshots.  Snapshots older than this number deleted."
  echo -e "          Default if not set: 7 [OPTIONAL]"
  echo -e "\n"
  echo -e "    -h    Number of hours to keep snapshots.  Snapshots older than this number deleted."
  echo -e "          Default if not set: 5 [OPTIONAL]"
  echo -e "\n"
  echo -e "    -m    Number of months to keep snapshots.  Snapshots older than this number deleted."
  echo -e "          Default if not set: 3 [OPTIONAL]"
  echo -e "\n"
  echo -e "    -p    Prefix for snapshot name."
  echo -e "          Default is no prefix [OPTIONAL]"
  echo -e "\n"
  echo -e "    -w    Number of weeks to keep snapshots.  Snapshots older than this number deleted."
  echo -e "          Default if not set: 2 [OPTIONAL]"
  echo -e "\n"
  echo -e "    -y    Number of years to keep snapshots.  Snapshots older than this number deleted."
  echo -e "          Default if not set: 2 [OPTIONAL]"
  echo -e "\n"
  exit 1
}

#
# SOME DEFAULTS, BASED ON GIVENOPTION, FOR $OLDER_THAN
#
TIMEZONE_OFFSET="-7 hours";
DEFAULT_PREFIX="daily-"
DEFAULT_TIMEFRAME="days"
DEFAULT_OLDERTHAN_DAYS=7
DEFAULT_OLDERTHAN_HOURS=5
DEFAULT_OLDERTHAN_WEEKS=2
DEFAULT_OLDERTHAN_MONTHS=3
DEFAULT_OLDERTHAN_YEARS=2

#
# GETS SCRIPT OPTIONS AND SETS GLOBAL VAR $OLDER_THAN
#

setScriptOptions()
{
    #  We use days as default if not options are give, so set a default
	OLDER_THAN=$DEFAULT_OLDERTHAN_DAYS
    PREFIX=$DEFAULT_PREFIX"daily-"
    TIMEFRAME=$DEFAULT_TIMEFRAME"days"
	CUSTOM_PREFIX=""

    while getopts ":d:h:m:p:w:y:" o; do
      case "${o}" in
        d)
          param=${OPTARG}
          OLDER_THAN=$DEFAULT_OLDERTHAN_DAYS
          PREFIX="daily-"
          TIMEFRAME="days"
          ;;

        h)
          param=${OPTARG}
          OLDER_THAN=$DEFAULT_OLDERTHAN_HOURS
          PREFIX="hourly-"
          TIMEFRAME="hours"
          ;;

        m)
          param=${OPTARG}
          OLDER_THAN=$DEFAULT_OLDERTHAN_MONTHS
          PREFIX="monthly-"
          TIMEFRAME="months"
          ;;

        p)
          CUSTOM_PREFIX=${OPTARG}"-"
          ;;

        w)
          param=${OPTARG}
          OLDER_THAN=$DEFAULT_OLDERTHAN_WEEKS
          PREFIX="weekly-"
          TIMEFRAME="weeks"
          ;;

        y)
          param=${OPTARG}
          OLDER_THAN=$DEFAULT_OLDERTHAN_YEARS
          PREFIX="yearly-"
          TIMEFRAME="years"
          ;;

        *)
          usage
          ;;
      esac
    done
    shift $((OPTIND-1))

    logTime "Param was "${param}""

	if [[ -n $param ]];then
      OLDER_THAN=$param
    fi

    PREFIX=${CUSTOM_PREFIX}${PREFIX}
	logTime "Executing snapshot with Prefix(${PREFIX}), with delete Timeframe(-${OLDER_THAN} ${TIMEFRAME})"
}


#
# RETURNS INSTANCE NAME
#

getInstanceName()
{
    # get the name for this vm
    local instance_name="$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/hostname" -H "Metadata-Flavor: Google")"

    # strip out the instance name from the fullly qualified domain name the google returns
    echo -e "${instance_name%%.*}"
}


#
# RETURNS INSTANCE ID
#

getInstanceId()
{
    echo -e "$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/id" -H "Metadata-Flavor: Google")"
}


#
# RETURNS INSTANCE ZONE
#

getInstanceZone()
{
    local instance_zone="$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/zone" -H "Metadata-Flavor: Google")"

    # strip instance zone out of response
    echo -e "${instance_zone##*/}"
}


#
# RETURNS LIST OF DEVICES
#
# input: ${INSTANCE_NAME}
#

getDeviceList()
{
    echo "$(gcloud compute disks list --filter users~$1\$ --format='value(name)')"
}


#
# RETURNS SNAPSHOT NAME
#

createSnapshotName()
{
    # create snapshot name
    local name="${PREFIX}gcs-$1-$2-$3"

    # google compute snapshot name cannot be longer than 62 characters
    local name_max_len=62

    # check if snapshot name is longer than max length
    if [ ${#name} -ge ${name_max_len} ]; then

        # work out how many characters we require - prefix + device id + timestamp
        local req_chars="${PREFIX}gcs--$2-$3"

        # work out how many characters that leaves us for the device name
        local device_name_len=`expr ${name_max_len} - ${#req_chars}`

        # shorten the device name
        local device_name=${1:0:device_name_len}

        # create new (acceptable) snapshot name
        name="${PREFIX}gcs-${device_name}-$2-$3" ;

    fi

    echo -e ${name}
}


#
# CREATES SNAPSHOT AND RETURNS OUTPUT
#
# input: ${DEVICE_NAME}, ${SNAPSHOT_NAME}, ${INSTANCE_ZONE}
#

createSnapshot()
{
    echo -e "$(gcloud compute disks snapshot $1 --snapshot-names $2 --zone $3)"
}


#
# GETS LIST OF SNAPSHOTS AND SETS GLOBAL ARRAY $SNAPSHOTS
#
# input: ${SNAPSHOT_REGEX}
# example usage: getSnapshots "(gcs-.*${INSTANCE_ID}-.*)"
#

getSnapshots()
{
    # create empty array
    SNAPSHOTS=()

    # get list of snapshots from gcloud for this device
    local gcloud_response="$(gcloud compute snapshots list --filter="name~'"$1"'" --uri)"

    # loop through and get snapshot name from URI
    while read line
    do
        # grab snapshot name from full URI
        snapshot="${line##*/}"

        # add snapshot to global array
        SNAPSHOTS+=(${snapshot})

    done <<< "$(echo -e "$gcloud_response")"
}


#
# RETURNS SNAPSHOT CREATED DATE
#
# input: ${SNAPSHOT_NAME}
#

getSnapshotCreatedDate()
{
    local snapshot_datetime="$(gcloud compute snapshots describe $1 | grep "creationTimestamp" | cut -d " " -f 2 | tr -d \')"

    #  format date
    echo -e "$(date -d ${snapshot_datetime%?????} +%Y%m%d%H)"
    
    # Previous Method of formatting date, which caused issues with older Centos
    #echo -e "$(date -d ${snapshot_datetime} +%Y%m%d)"
}


#
# RETURNS DELETION DATE FOR ALL SNAPSHOTS
#
# input: ${OLDER_THAN}
#

getSnapshotDeletionDate()
{
    echo -e "$(date -d "-$1 ${TIMEFRAME} ${TIMEZONE_OFFSET}" +"%Y%m%d%H")"
}


#
# RETURNS ANSWER FOR WHETHER SNAPSHOT SHOULD BE DELETED
#
# input: ${DELETION_DATE}, ${SNAPSHOT_CREATED_DATE}
#

checkSnapshotDeletion()
{
    if [ $1 -ge $2 ]

        then
            echo -e "1"
        else
            echo -e "2"

    fi
}


#
# DELETES SNAPSHOT
#
# input: ${SNAPSHOT_NAME}
#

deleteSnapshot()
{
    echo -e "$(gcloud compute snapshots delete $1 -q)"
}


logTime()
{
    local datetime="$(date +"%Y-%m-%d %T")"
    echo -e "$datetime: $1"
}


#######################
##                   ##
## WRAPPER FUNCTIONS ##
##                   ##
#######################


createSnapshotWrapper()
{
    # log time
    logTime "Start of createSnapshotWrapper"

    # get date time
    DATE_TIME="$(date "+%s")"

    # get the instance name
    INSTANCE_NAME=$(getInstanceName)

    # get the device id
    INSTANCE_ID=$(getInstanceId)

    # get the instance zone
    INSTANCE_ZONE=$(getInstanceZone)

    # get a list of all the devices
    DEVICE_LIST=$(getDeviceList ${INSTANCE_NAME})

    # create the snapshots
    echo "${DEVICE_LIST}" | while read DEVICE_NAME
    do
        # create snapshot name
        SNAPSHOT_NAME=$(createSnapshotName ${DEVICE_NAME} ${INSTANCE_ID} ${DATE_TIME})        

        # create the snapshot
        OUTPUT_SNAPSHOT_CREATION=$(createSnapshot ${DEVICE_NAME} ${SNAPSHOT_NAME} ${INSTANCE_ZONE})
    done
}

deleteSnapshotsWrapper()
{
    # log time
    logTime "Start of deleteSnapshotsWrapper"

    # get the deletion date for snapshots
    DELETION_DATE=$(getSnapshotDeletionDate "${OLDER_THAN}")

	#logTime "DELETION_DATE is set to ${DELETION_DATE})"

    # get list of snapshots for regex - saved in global array
    getSnapshots "${PREFIX}gcs-.*${INSTANCE_ID}-.*"

    # loop through snapshots
    for snapshot in "${SNAPSHOTS[@]}"
    do
        # get created date for snapshot
        SNAPSHOT_CREATED_DATE=$(getSnapshotCreatedDate ${snapshot})
		#logTime "SNAPSHOT_CREATED_DATE is set to ${SNAPSHOT_CREATED_DATE})"

        # check if snapshot needs to be deleted
        DELETION_CHECK=$(checkSnapshotDeletion ${DELETION_DATE} ${SNAPSHOT_CREATED_DATE})

        # delete snapshot
        if [ "${DELETION_CHECK}" -eq "1" ]; then
           OUTPUT_SNAPSHOT_DELETION=$(deleteSnapshot ${snapshot})
        fi

    done
}




##########################
##                      ##
## RUN SCRIPT FUNCTIONS ##
##                      ##
##########################

# log time
logTime "Start of Script"

# set options from script input / default value
setScriptOptions "$@"

# create snapshot
createSnapshotWrapper

# delete snapshots older than 'x' days
deleteSnapshotsWrapper

# log time
logTime "End of Script"
