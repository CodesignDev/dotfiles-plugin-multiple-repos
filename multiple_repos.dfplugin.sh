#!/usr/bin/env bash
set +e

# Running in df core check
[[ -z "$DF_PLUGIN" ]] && return

# Get our current directory
MULTIPLE_REPOS_PLUGIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Some default variables
MULTIPLE_REPOS_DIR=${MULTIPLE_REPOS_DIR:-"$HOME/.df-repos"}
MULTIPLE_REPOS_BACKUP_DIR=${MULTIPLE_REPOS_BACKUP_DIR:-"$MULTIPLE_REPOS_DIR/.backups"}

MULTIPLE_REPOS_DEFAULT_REPO_HOST=${MULTIPLE_REPOS_DEFAULT_REPO_HOST:-"github.com"}
MULTIPLE_REPOS_DEFAULT_REPO_USER=${MULTIPLE_REPOS_DEFAULT_REPO_USER:-$GITHUB_USER}
MULTIPLE_REPOS_PREFER_GIT_SCHEME=${MULTIPLE_REPOS_PREFER_GIT_SCHEME:-"https"}
MULTIPLE_REPOS_FORCE_ADD_GIT_EXTENSION=${MULTIPLE_REPOS_FORCE_ADD_GIT_EXTENSION:-0}

MULTIPLE_REPOS_REPO_DIRECTORY_PREFIX=${MULTIPLE_REPOS_REPO_DIRECTORY_PREFIX:-""}

MULTIPLE_REPOS_INITED=0

dotfile_plugin_multiple_repos_plugin_init() {

    # Add hooks
    hook init dotfile_plugin_multiple_repos_init
    hook cleanup dotfile_plugin_multiple_repos_cleanup
    hook bootstrap_start dotfile_plugin_multiple_repos_install_prerequisites
    hook bootstrap_start dotfile_plugin_multiple_repos_init_repos
    hook install_start dotfile_plugin_multiple_repos_install_prerequisites
    hook install_start dotfile_plugin_multiple_repos_init_repos
    hook after_topic dotfile_plugin_multiple_repos_run
}

dotfile_plugin_multiple_repos_init() {

    # Create our storage directory
    [[ ! -d $MULTIPLE_REPOS_DIR ]] && mkdir -p $MULTIPLE_REPOS_DIR
    [[ ! -d $MULTIPLE_REPOS_BACKUP_DIR ]] && mkdir -p $MULTIPLE_REPOS_BACKUP_DIR

    # Reset some variables
    MULTIPLE_REPOS_INITED=0

    # Create a temporary directory to store our processed repo list
    MULTIPLE_REPOS_PROCESSED_REPO_DIR=$(mktemp -d -t df-plugin-processed-repo.XXXXXXXX)
    [[ ! -d $MULTIPLE_REPOS_PROCESSED_REPO_DIR ]] && mkdir -p $MULTIPLE_REPOS_PROCESSED_REPO_DIR

    return 0
}

dotfile_plugin_multiple_repos_cleanup() {

    # Delete our processed repo list
    [[ -d $MULTIPLE_REPOS_PROCESSED_REPO_DIR ]] && rm -rf $MULTIPLE_REPOS_PROCESSED_REPO_DIR

    return 0
}

dotfile_plugin_multiple_repos_install_prerequisites() {

    # Skip if we have already installed the prereqs
    [[ -z $MULTIPLE_REPOS_PREREQS_INSTALLED ]] || return 0

    # Install prerequisites
    install_package git

    # Say that we have installed the prereqs
    MULTIPLE_REPOS_PREREQS_INSTALLED=1
}

dotfile_plugin_multiple_repos_init_repos() {

    # Local variables
    local REPO_LIST_PATH
    local REPO_LIST
    local REPO
    local REPO_DIRECTORY
    local REPO_BACKUP_DATE
    local REPO_DIR
    local REPO_BACKUP_DIR

    # Check if git is installed, bail if it isn't. This is before the init check
    # so it can be run later if needed without locking the whole initialization out
    command_exists git || return 0

    # Skip initialization if this has already been run
    [[ "$MULTIPLE_REPOS_INITED" == "1" ]] && return 0
    MULTIPLE_REPOS_INITED=1

    # Skip install of extra repos if needed
    [[ -z $SKIP_REPO_INSTALL ]] || return 0

    # If the root dotfiles isn't specified, skip
    [[ -z $DOTFILES_DIR ]] && return 0

    # Print a message to the terminal
    line "Downloading repositories..."

    # Get the path to the file list
    REPO_LIST_PATH=$(dotfile_plugin_multiple_repos_get_repo_list_path)

    # Read the list of repos from the file
    REPO_LIST=($(dotfile_plugin_multiple_repos_read_repo_list $REPO_LIST_PATH))

    # Remove duplicates from the list
    REPO_LIST=($(echo ${REPO_LIST[@]} | tr ' ' '\n' | sort -u | tr '\n' ' '))

    # Loop through each repo
    for REPO in ${REPO_LIST[@]}; do

        # Get the local directory name for the repo
        REPO_DIRECTORY=$(dotfile_plugin_multiple_repos_get_repo_directory_name $REPO)

        # Show message to say checking repository
        line "Checking repository '$REPO'..."

        # Run the git ls-remote command, catching the output and exit code
        GIT_CMD_OUTPUT="$(git ls-remote -h $REPO 2>&1)"
        GIT_CMD_EXIT_CODE=$?

        # Check if we can access the repository
        if [[ $GIT_CMD_EXIT_CODE -gt 0 ]]; then

            # Determine the exit code
            case $GIT_CMD_EXIT_CODE in

                # Git error exit code
                128)

                    # Check for failed authentication
                    if echo $GIT_CMD_OUTPUT | grep $QUIET_FLAG_GREP 'Authentication failed'; then

                        # Print an error message
                        error "Unable to authenticate with git. Please check your login details and try again*."

                        # This error is an automatic bail
                        return 0

                    # Check if git said that the repo doesn't exist
                    elif echo $DIT_CMD_OUTPUT | grep $QUIET_FLAG_GREP "repository '.*' not found"; then

                        # Print a warning message
                        warning "Skipping repository as unable to access it."

                    # Any other error
                    else

                        # Print a message
                        error "An error occured while checking the repository."

                    fi
                    ;;

                # Unknown exit code
                *)
                    error "An error occured while checking the repository."
                    ;;

            esac

            # Skip this repository
            continue

        fi

        # Set the relevant git dir env variables*
        export GIT_DIR="$MULTIPLE_REPOS_DIR/$REPO_DIRECTORY/.git"
        export GIT_WORK_TREE="$MULTIPLE_REPOS_DIR/$REPO_DIRECTORY"

        # Update this repo if the repo directory already exists
        if [[ -d "$MULTIPLE_REPOS_DIR/$REPO_DIRECTORY" ]]; then

            # Print update message
            line "Updating local repository..."

            # Do a git pull on the repo
            git pull $QUIET_FLAG_GIT origin master

        # Repo doesn't exist locally so set up a local version
        else

            # Print a message saying that the repo is being downloaded
            line "Creating local repository..."

            # Create the directory
            mkdir -p "$MULTIPLE_REPOS_DIR/$REPO_DIRECTORY"

            # Import the repo into the directory
            git init $QUIET_FLAG_GIT
            git config remote.origin.url "$REPO"
            git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"

            # Fetch and reset the work tree
            git fetch $QUIET_FLAG_GIT --force
            git reset $QUIET_FLAG_GIT --hard origin/master
        fi

        # Clear the git directory and work tree variables
        unset GIT_DIR GIT_WORK_TREE

        # Add a file to the processed repo directory
        touch $MULTIPLE_REPOS_PROCESSED_REPO_DIR/$REPO_DIRECTORY

    done

    # Get the current date
    REPO_BACKUP_DATE=$(date '+%Y%m%d')

    # Loop through all repos in the folder
    for DIR in $MULTIPLE_REPOS_DIR/*/; do

        # Strip the slash from the end
        DIR=${DIR%/}

        # Stop processing if the directory isn't valid
        [[ ${DIR: -1} == "*" ]] && continue

        # Skip if this is the backups directory
        [[ "$DIR" == "$MULTIPLE_REPOS_BACKUP_DIR" ]] && continue

        # Get the directory itself instead of the full path
        REPO_DIR=$(basename $DIR)

        # Skip this directory if it is one that we have just processed
        [[ -f "$MULTIPLE_REPOS_PROCESSED_REPO_DIR/$REPO_DIR" ]] && continue

        # Get the name of the directory for backups
        BACKUP_DIR="${REPO_DIR}_${REPO_BACKUP_DATE}"

        # Remove any backup directories that exist
        [[ -d "$MULTIPLE_REPOS_BACKUP_DIR/$BACKUP_DIR" ]] && rm -rf "$MULTIPLE_REPOS_BACKUP_DIR/$BACKUP_DIR"

        # Move the actual directory into the backups directory
        mv "$DIR" "$MULTIPLE_REPOS_BACKUP_DIR/$BACKUP_DIR"

    done
}

dotfile_plugin_multiple_repos_run() {
    local ROOT_DIR=$1
    local FILE=$2

    # Check if we are running in our root folder, prevents feedback loop
    echo $ROOT_DIR | grep $QUIET_FLAG_GREP "$MULTIPLE_REPOS_DIR" 2>/dev/null && return 0

    # Loop through each directory in the repos folder
    for DIR in $MULTIPLE_REPOS_DIR/*/; do

        # Strip the slash from the end
        DIR=${DIR%/}

        # Stop processing if the directory isn't valid
        [[ ${DIR: -1} == "*" ]] && continue
        [[ "$DIR" == "$MULTIPLE_REPOS_BACKUP_DIR" ]] && continue

        # Run the topic scripts in that directory
        run_topic_scripts $DIR $FILE

    done
}

dotfile_plugin_multiple_repos_get_repo_list_path() {

    # Variables
    local REPO_LIST_DIRECTORIES=()
    local REPO_LIST_FILE_PREFIXES=()
    local REPO_LIST_FILE_NAMES=()
    local REPO_LIST_FILE_EXTS=()
    local REPO_LIST_FILES=()

    # Shortcut this function if a file has been passed via env variables
    if ! [[ -z $MULTIPLE_REPOS_FILE_LIST ]]; then
        dotfile_plugin_multiple_repos_get_repo_list_file $MULTIPLE_REPOS_FILE_LIST && return 0
    fi

    # Directories where the repo list file could be stored
    REPO_LIST_DIRECTORIES=("." "$DOTFILES_DIR" "$HOME")

    # List of possible file prefixes
    REPO_LIST_FILE_PREFIXES=(dotfiles dotfile df)

    # List of possible file names for the repo list file
    REPO_LIST_FILE_NAMES=(
        "repo-list"
        "repolist"
        "repos"
    )

    # Add extra extensions for the file
    REPO_LIST_FILE_EXTS=(json txt list)

    # Add prefix variants
    for PREFIX in ${REPO_LIST_FILE_PREFIXES[@]}; do
        for NAME in ${REPO_LIST_FILE_NAMES[@]}; do
            REPO_LIST_FILES+=($PREFIX-$NAME)
        done
    done

    # Add possible alternate names
    for NAME in ${REPO_LIST_FILES[@]}; do REPO_LIST_FILES+=($(echo $NAME | sed -r 's/-/_/g')); done
    for NAME in ${REPO_LIST_FILES[@]}; do REPO_LIST_FILES+=(.$NAME); done

    # Check for each possible file combination, returning the first result found
    for DIR in ${REPO_LIST_DIRECTORIES[@]}; do
        for NAME in ${REPO_LIST_FILES[@]}; do
            for EXT in ${REPO_LIST_FILE_EXTS[@]}; do
                dotfile_plugin_multiple_repos_get_repo_list_file $DIR/$NAME.$EXT && return 0
            done
            dotfile_plugin_multiple_repos_get_repo_list_file $DIR/$NAME && return 0
        done
    done
    return 0
}

dotfile_plugin_multiple_repos_get_repo_list_file() {
    local FILE=$1

    # Bail if the file doesn't exist
    [[ -f $FILE ]] || return 1

    # Return the file path
    echo $FILE
    return 0
}

dotfile_plugin_multiple_repos_read_repo_list() {
    local FILE_PATH=$1

    local IS_JSON_FILE=0

    # Check if the file is valid
    [[ -f $FILE_PATH ]] || return 0

    # Check if the file is a json file
    cat $FILE_PATH | jq empty 2>/dev/null && IS_JSON_FILE=1

    # Read the file in the relevant parser
    if [[ "$IS_JSON_FILE" == "1" ]]; then
        dotfile_plugin_multiple_repos_parse_repo_list_file_json $FILE_PATH && return 0
    else
        dotfile_plugin_multiple_repos_parse_repo_list_file_text $FILE_PATH && return 0
    fi
    return 0
}

dotfile_plugin_multiple_repos_parse_repo_list_file_json() {
    local FILE=$1

    local REPO_LINES=()
    local PARSED_REPO_LINES=()
    local JSON_KEY
    local JQ_EXPRESSION

    # Check that the file is valid
    [[ -f $FILE ]] || return 1

    # Detect the JSON key being used
    jq -e -r 'has("repositories")' $FILE >/dev/null && JSON_KEY=repositories
    jq -e -r 'has("repos")' $FILE >/dev/null && JSON_KEY=repos

    # Bail if no key was found
    [[ "$JSON_KEY" == "" ]] && return 1

    # Read the data from the json file
    JQ_EXPRESSION=".$JSON_KEY[]"
    REPO_LINES=($(jq -r "$JQ_EXPRESSION" $FILE))

    # Parse each of the lines
    for LINE in ${REPO_LINES[@]}; do
        PARSED_REPO_LINES+=($(dotfile_plugin_multiple_repos_parse_repo_list_line $LINE))
    done

    # Return the list of repo lines
    echo ${PARSED_REPO_LINES[@]}
    return 0
}

dotfile_plugin_multiple_repos_parse_repo_list_file_text() {
    local FILE=$1

    local REPO_LINES=()
    local PARSED_REPO_LINES=()

    # Check that the file is valid
    [[ -f $FILE ]] || return 1

    # Loop through each line in the file
    while IFS= read -r LINE || [[ -n "$LINE" ]]; do

        # Ignore comments
        [[ ${LINE:0:1} == "#" ]] && continue

        # Add the line to the lsit
        REPO_LINES+=($LINE)

    done < $FILE

    # Parse each line
    for LINE in ${REPO_LINES[@]}; do
        PARSED_REPO_LINES+=($(dotfile_plugin_multiple_repos_parse_repo_list_line $LINE))
    done

    # Return the list of repo lines
    echo ${PARSED_REPO_LINES[@]}
    exit
    return 0
}

dotfile_plugin_multiple_repos_parse_repo_list_line() {
    local LINE=$1

    local REPO
    local REPO_USER
    local REPO_NAME
    local REPO_URL
    local REPO_PROTOCOL
    local REPO_HOST
    local REPO_SEPARATOR
    local REPO_HTTP_USER
    local REPO_HOST_PORT
    local REPO_HTTP_PORT
    local REPO_PATH

    local HAS_PROTOCOL
    local HAS_DOMAIN

    # If the line starts with a slash or file://, then don't parse it, treat it as is
    if dotfile_plugin_multiple_repos_is_local_file_repo $LINE; then
        echo $LINE
        return 0
    fi

    # Get and remove the protocol
    REPO_PROTOCOL=$(echo $LINE | grep :// | grep -o '^\([A-Za-z]*://\)')
    LINE=${LINE#"$REPO_PROTOCOL"}

    # Get and remove the user
    REPO_HTTP_USER=$(echo $LINE | grep @ | cut -d @ -f 1)
    LINE=${LINE#"$REPO_HTTP_USER@"}

    # Get the host/port if we have one
    REPO_HOST_PORT=$(echo $LINE | grep -o '^\([A-Za-z0-9.\-_]*\.[A-Za-z0-9]*\)\(:[0-9]\{1,5\}\)\?')
    LINE=${LINE#"$REPO_HOST_PORT"}

    # Get the separator that is used between the host and path
    REPO_SEPARATOR=$(echo $LINE | grep -o '^\([:/]\)')
    LINE=${LINE#"$REPO_SEPARATOR"}

    # Get the repo path from the rest of the url
    REPO_PATH=$(echo $LINE | grep -o '^\([A-Za-z0-9\-_/]*/\)\?\([A-Za-z0-9_\-]*\)\(\.git\)\?')

    # Split the host/port up
    REPO_HOST=$(echo $REPO_HOST_PORT | cut -d : -f 1)
    REPO_HTTP_PORT=$(echo $REPO_HOST_PORT | grep : | cut -d : -f 2)

    # Separate the path into user/repo
    REPO_NAME=$(basename $REPO_PATH)
    REPO_USER=$(dirname $REPO_PATH)

    # Check if we are adding the .git extension to the repo name
    if [[ "$MULTIPLE_REPOS_FORCE_ADD_GIT_EXTENSION" == "1" ]]; then
        REPO_NAME=${REPO_NAME%.git}.git
    fi

    # If there is no host, set some defaults
    if [[ -z $REPO_HOST ]]; then

        # If there is no user, assume its our GH user. Only if we don't have a host]]
        [[ -z $REPO_USER ]] && REPO_USER=$MULTIPLE_REPOS_DEFAULT_REPO_USER

        # Set the host
        REPO_HOST=$MULTIPLE_REPOS_DEFAULT_REPO_HOST

        # Set the http user and separator depending on the default
        case $MULTIPLE_REPOS_PREFER_GIT_SCHEME in

            # http / https - No user and default URL based separator
            https | http)
                REPO_HTTP_USER=""
                REPO_SEPARATOR="/"
                ;;

            # git or ssh - Add default git user and ssh style separator
            git | ssh)
                REPO_HTTP_USER="git"
                REPO_SEPARATOR=":"
                ;;

            # Unknown - Use the same as https
            *)
                REPO_HTTP_USER=""
                REPO_SEPARATOR="/"
                ;;
        esac
    fi

    # Check if we need to add a protocol
    if [[ -z $REPO_PROTOCOL ]]; then

        # The only thing we can use to check this is the separator
        # Let's check to see if the separator is a url based separator, if so, set the protocol to https
        # git or ssh doesn't have a protocol
        [[ "$REPO_SEPARATOR" == "/" ]] && REPO_PROTOCOL="https://"
    fi

    # Add some extra data to the variables if needed
    [[ -z $REPO_HTTP_USER ]] || REPO_HTTP_USER="$REPO_HTTP_USER@"
    [[ -z $REPO_USER ]] || REPO_USER="$REPO_USER/"


    # Merge the parts together
    REPO="$REPO_PROTOCOL$REPO_HTTP_USER$REPO_HOST$REPO_SEPARATOR$REPO_USER$REPO_NAME"

    # Return the repo url
    echo $REPO
    return 0
}

dotfile_plugin_multiple_repos_is_local_file_repo() {
    local REPO=$1

    [[ "${REPO:0:1}" == "." ]] && return 0
    [[ "${REPO:0:1}" == "/" ]] && return 0
    [[ "$REPO" =~ ^file:\/\/.* ]] && return 0

    return 1
}

dotfile_plugin_multiple_repos_get_repo_directory_name() {
    local REPO=$1
    local REPO_DIRECTORY

    # Convert all special characters in the url to underscores
    REPO_DIRECTORY=$(echo $REPO | tr '.:\\\/\-+' '_')

    # Add a prefix to the directory if required
    if [[ -n $MULTIPLE_REPOS_REPO_DIRECTORY_PREFIX ]]; then
        REPO_DIRECTORY=${MULTIPLE_REPOS_REPO_DIRECTORY_PREFIX}_${REPO_DIRECTORY}
    fi

    # Return the result
    echo $REPO_DIRECTORY
    return 0
}

hook plugin_init dotfile_plugin_multiple_repos_plugin_init
