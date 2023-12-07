#!/bin/bash

file="../src/cuda/groupby.cu"

# Start value
value=2.2

# End value
end_value=3.4

# While loop to increase the value by 0.1 until it reaches 3.5
while (( $(echo "$value <= $end_value" | bc -l) ))
do
    # Use sed to replace the current value with the new value in the 55th line
    sed -i "55s/const float THRESHOLD = [0-9]\+\(\.[0-9]\+\)\?;/const float THRESHOLD = $value;/" $file
    bash video_acc.sh 0 204
    # Increase value by 0.1
    value=$(echo "$value + 0.2" | bc -l)

    # Optional: Print the current value for verification
    echo "Set THRESHOLD to $value"
done
