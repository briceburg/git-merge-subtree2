#!/bin/bash

SCRIPT_DIR=$( dirname $( readlink -e $0 ) )
. "$SCRIPT_DIR/../_utils.sh"


IS_MSYS=
[[ "$(uname -a)" == *Msys* ]] && IS_MSYS=true

NL=$'\n'
TEST_PATTERNS=(
    # wildcards
    '*' '**' '***' '**f*' '**/*' '*/**' '*/*' '**.txt' '***.txt' '****.txt' '**/*/*.txt' '*d?r/*.*.txt' '**/d?r*/*/*.txt'
    
    # character groups
    '*/D?[!0-9]/*.txt' '[^a-z][!a-zA-Z]/*.txt' '**/*.?[]' '**/*.?[][]?' '**/*.?[[]?' '**/*.??[]]' '**/*.?[!]]]' '**/*.?[^]]]' '**/*.?[?'
    
    # leading ./ or / & more wildcards
    '/**.txt' '/**/*/*.txt' './**.txt' './**/*/*.txt'
    
    # special characters
    '.@?!,^$+-()[]{}.txt' '**/*.?()' '**/*.*)*' '**/*.*(*' '[$.^]@.!,[$^*][*$+][-+?][?\-(][)([][[)\]][][{][{\]}][}{\\][\\}|].txt'
    
    # escape sequences
    '[!\\]*' '**/*.[\!\(\)\[\]][\(\)\[\]!][\^\(\)\[\]]' '**/*.\!\(\)' '**/*.\t\x\t' '**/*.?[\]'
)

# note: *:?\ can't be used on windows
if [[ -z IS_MSYS ]]; then
    TEST_PATTERNS+=(
        'subtree/d[*:?\][^*:?\][^*:?\\]/*.file'
        'subtree/d\*r\?/:\\.file'
    )
fi

function the-test() {
    # work around git-for-windows/git#1019
    # https://github.com/git-for-windows/git/issues/1019
    export MSYS="noglob"
    export MSYS_NO_PATHCONV=1

    # Initialize repo
    mkdir -p repo && cd repo
    git init
    
    # Initialize source branch
    git checkout --orphan source
    
    
    mkdir subtree
    mkdir subtree/A9
    mkdir subtree/d_r
    mkdir subtree/d-r
    mkdir subtree/d+r
    mkdir 'subtree/d*r'
    mkdir subtree/dir
    mkdir subtree/dir.!
    mkdir subtree/dir/DIR
    
    local CONTENT="source branch"
    echo -n $CONTENT > 'subtree/.@.!,^$+-()[]{}.txt'
    echo -n $CONTENT > subtree/file.txt
    echo -n $CONTENT > subtree/.file.bin
    echo -n $CONTENT > subtree/A9/file.txt
    echo -n $CONTENT > subtree/A9/other.ext    
    echo -n $CONTENT > subtree/d_r/file.txt
    echo -n $CONTENT > subtree/d-r/strange.\!\(\)
    echo -n $CONTENT > subtree/d+r/strange.\@\(\)
    echo -n $CONTENT > subtree/dir/.file.txt
    echo -n $CONTENT > subtree/dir/crazy.![]
    echo -n $CONTENT > subtree/dir.!/file.txt
    echo -n $CONTENT > subtree/dir.!/.other.txt
    echo -n $CONTENT > subtree/dir/DIR/.more.txt
    echo -n $CONTENT > subtree/dir/DIR/more.bin
    
    # note: *:?\ can't be used on windows
    if [[ -z IS_MSYS ]]; then
        echo -n $CONTENT > 'subtree/d*r?/:\.file'
    fi
    
    # Calculate expected file sets using bash builtin globbing
    (
        mkdir results
        cd subtree
    
        set +x
        
        LC_ALL="C"
        shopt -s globstar
        shopt -s dotglob
        shopt -s nullglob
        shopt -u extglob
        
        echo "=== Expected results"
        
        for (( i=0; i < ${#TEST_PATTERNS[@]}; i++ )); do
            local RESULT=""
            
            # remove leading './' or '/'
            local PATTERN="${TEST_PATTERNS[$i]#./}"
            PATTERN="${PATTERN#/}"
            
            for path in $PATTERN; do 
                [[ -f "$path" ]] && RESULT+="$path$NL"
            done
            
            echo -n "$RESULT" | sort > ../results/$i.txt
            echo "--- TEST_PATTERNS[$i]: ${TEST_PATTERNS[$i]}"
            cat ../results/$i.txt
        done
        
        echo "==="
    )
    
    git add -A
    git commit -m "source: initial commit"

    # Initialize target branch
    git checkout --orphan target
    git reset --hard
        
    echo "target branch" > file.txt
    git add -A
    git commit -m "target: initial commit"

    # Initialize subproject
    git subproject init results source --their-prefix=results
    
    # Initialize different subprojects with the patterns and compare the result
    # with bash's built-in globbing
    local AGGREGATED_ERRORS=( )
    for (( i=0; i < ${#TEST_PATTERNS[@]}; i++ )); do
        local IS_FAILURE="false"
    
        if ! git subproject init "filter-test-$i" source --their-prefix=subtree --filter-is-glob --filter="${TEST_PATTERNS[$i]}" ; then 
            IS_FAILURE="true"
        elif ! find "filter-test-$i" -type f -printf '%P\n' | sort | diff -y results/$i.txt - ; then
            IS_FAILURE="true"
        fi
        
        if [[ $IS_FAILURE == "true" ]]; then
            AGGREGATED_ERRORS+=( "FAILURE: TEST_PATTERNS[$i] = ${TEST_PATTERNS[$i]}" )
            ( set +x; echo "${AGGREGATED_ERRORS[-1]}" )
        fi
    done
    
    ( 
        set +x
        echo "Number of failed test patterns: ${#AGGREGATED_ERRORS[@]}"
    
        for ERROR in "${AGGREGATED_ERRORS[@]}"; do
            echo "    $ERROR"
        done
    )
    return ${#AGGREGATED_ERRORS[@]}  
}

invoke-test $@