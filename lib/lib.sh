#!/bin/bash
# This file contains library function useful for both the merge strategy and
# the subproject utility

#
# Constants
GIT_REPO=$( git rev-parse --git-dir )
EMPTY_TREE=$( git hash-object -t tree /dev/null )
CRITICAL_EXIT_CODE=2
CAN_CONTINUE_EXIT_CODE=1
TRUE=0
FALSE=1
NL=$'\n'


#
# Functions

# exit with return value $CRITICAL_EXIT_CODE if the working directory contains
# 
# untracked files or local changes
function fail-if-dirty() {
    local TRUE=0
    local FALSE=1
    local IS_DIRTY=$FALSE
    
    if [[ -n "$(git status --porcelain)" ]]; then
        >&2 echo "ERROR: Working directory contains untracked files."
        IS_DIRTY=$TRUE
    fi
    
    git diff --no-ext-diff --quiet --exit-code
    if [[ $? -ne 0 ]]; then
        >&2 echo "ERROR: Working directory has local changes."
        IS_DIRTY=$TRUE
    fi
    
    if [[ $IS_DIRTY -eq $TRUE ]]; then
        >&2 echo "ERROR: Need to stage changes first."
        exit $CRITICAL_EXIT_CODE
    fi
}

# remove leading and trailing slashs, reduce duplicated slashs to single slashs
function normalize-prefix() {
    echo -n "$1" | sed -r -e "s/\/+/\//g" -e "s/^\/+//" -e "s/\/+$//" 
}

# Validate and resolve the branch/reference name stored in a variable named $1
# (first argument) to an unambigious name:
# 1) if the branch starts with "heads/" and "refs/$BRANCH" exists, "heads/" is
# stripped from the beginning of the branch name and the result is returned
# 2) if "refs/heads/$BRANCH" exist, "$BRANCH" is returned unchanged
# 3) if "refs/remotes/$BRANCH" exists, "remotes/$BRANCH" is returned
# 4) if "refs/$BRANCH" exists, "$BRANCH" is returned unchanged
# Arguments: <branch_var>
#    <branch_var>: variable storing the branch name to be verified and expanded
function resolve-branch() {
    declare -n BRANCH=$1
    
    # The result corresponding to the first matching candidate is returned
    local CANDIDATES=("heads/$BRANCH" "remotes/$BRANCH" "$BRANCH")
    local RESULTS=(   "$BRANCH"       "remotes/$BRANCH" "$BRANCH")
    if [[ "$BRANCH" == heads/* ]]; then
        CANDIDATES=( "$BRANCH"           "${CANDIDATES[@]}" )
        RESULTS=(    "${BRANCH##heads/}" "${RESULTS[@]}" )
    fi
    
    for ref in "${CANDIDATES[@]}"; do
        if git show-ref -q --verify "refs/$ref"; then
            BRANCH="${RESULTS[0]}"
            return 0
        fi
        
        CANDIDATES=( "${CANDIDATES[@]:1}" )
        RESULTS=( "${RESULTS[@]:1}" )
    done
    
    >&2 echo "ERROR: Branch not found: $BRANCH"
    return $CRITICAL_EXIT_CODE
}

# Set $1=$2 if [[ -z "$1" ]]
function set-if-zero() {
    declare -n VAR=$1
    if [[ -z "$VAR" ]]; then
        VAR=$2
    fi
}

# Prepare a tree for merging, such that only files matching a given prefix and
# filter regexp are considered for merging. 
# Arguments: <remote_tree_var> <remote_prefix> <local_tree> <local_prefix>
#   remote_tree_var: name of a variable referencing a tree object or branch
#                    - the variable is updated to reference the shifted tree
#                    object
#     remote_prefix: only files in the tree referenced by <tree_var>, whose paths
#                    start with <from_prefix> shall be considered for merging
#        local_tree: name of a the target tree object or branch
#      local_prefix: the prefix of paths matching <remote_prefix> is changed to
#                    <local_prefix>
#
# The resulting treeish contains files from from <tree_var> and <my_tree>:
#   - files from <local_tree> not matching <local_prefix>/*
#   - files from <remote_tree> matching <remote_prefix>/* and <filter_regex> 
#     with <remote_prefix> changed to <local_prefix>
function prepare-remote-tree() {
    local -n REMOTE_TREE_VAR=$1
    local REMOTE_PREFIX=$2
    local LOCAL_TREE=$3
    local LOCAL_PREFIX=$4
    local FILTER_REGEXP=$5

    local FROM_TREE="$REMOTE_TREE_VAR"
    
    # if specified, extract the tree object corresponding to $REMOTE_PREFIX
    if [[ -n "$REMOTE_PREFIX" ]]; then
        LS_TREE_RESULT=( $(git ls-tree -rd "$REMOTE_TREE_VAR" | grep --perl-regexp "\t$REMOTE_PREFIX$" --max-count 1) )
        
        if [[ -z ${LS_TREE_RESULT[@]} ]]; then
            >&2 echo "'$REMOTE_TREE_VAR' does not include a directory '$REMOTE_PREFIX'"
            return 2
        fi
        
        FROM_TREE=${LS_TREE_RESULT[2]}
    fi
    
    # use the index to prepare their tree
    if [[ -z "$LOCAL_PREFIX" ]]; then
        # the merge is not limited to a sub directory ($LOCAL_PREFIX) of
        # $LOCAL_TREE, hence there are no files outside $LOCAL_PREFIX to
        # preserve => prepare $FROM_TREE starting with an empty index
        git read-tree --empty
        git read-tree "$FROM_TREE"
    else 
        # the merge is limited to a sub directory ($LOCAL_PREFIX) of $MY_TREE,
        # hence there are files outside $LOCAL_PREFIX to preserve
        # => initialize $FROM_TREE using $LOCAL_TREE and replace everything below
        #    $LOCAL_PREFIX
        git reset --mixed "$LOCAL_TREE"
        git rm -q --cached "$LOCAL_PREFIX/*" &> /dev/null
        git read-tree --prefix="$LOCAL_PREFIX" "$FROM_TREE"
    fi
    
    if [[ -n "$FILTER_REGEXP" ]]; then
        git ls-files -c -- "$LOCAL_PREFIX" | sed -e "s/^$LOCAL_PREFIX\///" \
            | grep -v --perl-regexp "$FILTER_REGEXP" \
            | xargs  --replace git rm -rfq --cached "$LOCAL_PREFIX/{}"
    fi
        
    REMOTE_TREE_VAR=$(git write-tree)
}

# A merge strategy like built-in resolve.
# Based on https://github.com/git/git/blob/master/git-merge-resolve.sh
# Arguments: <local_tree> <remote_tree> <base_tree>
#  xxx_tree: id of a tree object to merge
function merge-resolve() {
    local LOCAL_TREE="$1"
    local REMOTE_TREE="$2"
    local BASE_TREE="$3"
    
    # Update index to match working directory, then merge trees
    git reset --mixed 
    git read-tree -m -u --aggressive $BASE_TREE $LOCAL_TREE $REMOTE_TREE || return $CRITICAL_EXIT_CODE

    # Read-tree does a simple merge, that might leave unresolved files behind
    # Using 'git write-tree' it is easy to test for unresolved files.
    echo "Trying simple merge."
    if result_tree=$(git write-tree 2>/dev/null); then
        return 0
    else 
        # see https://github.com/git/git/blob/master/git-merge-resolve.sh
        echo "Simple merge failed, trying Automatic merge."
        export MERGE_FILE_ARGS="$MERGE_FILE_CONFLICT_STYLE $MERGE_FILE_MODE"
        if git-merge-index -o git-merge-one-file2 -a
        then
            return 0
        else
            return $CAN_CONTINUE_EXIT_CODE
        fi
    fi
}