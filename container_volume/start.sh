#!/bin/bash

# Read the timer value from the mounted host file
TIMER_VALUE=$(awk '/^now/ {print $3; exit}' /host_timer_list)

# Save the value to the output file
echo "BOOTED - $TIMER_VALUE" >> /home/times.txt
