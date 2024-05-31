#!/bin/bash


# generate new squishy file wiht 
# docker run --rm -it -v $(pwd):/build --entrypoint 'sh' -w /build lalex/lua-squish
# and run make_squishy -> will output squishy.new.
# as it outputs absolute paths you will have to change them to relative

# just build off existing squishy file
docker run --rm -it -v $(pwd):/build -w /build lalex/lua-squish
npx aoform apply