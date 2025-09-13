#!/bin/bash

# this is the setup part, comment it out after the first execution
export DEBUG_LEVEL=WARNING 

mkdir -p ./audios
mkdir -p ./output

python -m venv .venv
source .venv/bin/activate

python -m pip install -r requirements.txt 
# end of setup part

python stitch.py -m "hello, Shreeshail" -a ./audios -o "./output/hello_shreeshail.mp3"