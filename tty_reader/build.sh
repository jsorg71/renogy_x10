#!/bin/sh

#PATH=/opt/zig-linux-x86_64-0.13.0:/usr/local/bin:/usr/bin:/bin
#PATH=/opt/zig-x86_64-linux-0.14.1:/usr/local/bin:/usr/bin:/bin
PATH=/opt/zig-x86_64-linux-0.15.1:/usr/local/bin:/usr/bin:/bin

listOfProjects="tty_reader"

# check that all projects exist
for proj in $listOfProjects
do
    if test -d "../$proj"
    then
        :
    else
        echo "Directory ../$proj does not exits"
        exit 1
    fi
done
echo "all projects exist"

# clean
if [ "$1" = "clean" ]
then
    for proj in $listOfProjects
    do
        echo "clean ../$proj"
        cd ../$proj
        rm -f -r .zig-cache/ zig-out/
    done
    exit 0
fi

# debug build
if [ "$1" = "debug" ]
then
    for proj in $listOfProjects
    do
        echo "building debug ../$proj"
        cd ../$proj
        zig build --summary all
        if test $? -ne 0
        then
            exit 1
        fi
    done
    exit 0
fi

# status
if [ "$1" = "status" ]
then
    for proj in $listOfProjects
    do
        echo "status ../$proj"
        cd ../$proj
        git status -s -uno
    done
    exit 0
fi

# release build
for proj in $listOfProjects
do
    echo "building ../$proj"
    cd ../$proj
    zig build -Doptimize=ReleaseFast -Dstrip=true --summary all
    if test $? -ne 0
    then
        exit 1
    fi
done
