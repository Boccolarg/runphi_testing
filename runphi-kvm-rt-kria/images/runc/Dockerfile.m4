# rt-cyclictest:runc for the students' own procedure (bench/m4.py): the
# campaign's runc image (Dockerfile, rtbench-runc:alpine) with the same
# cyclictest binary, but no entrypoint and no rtbench.sh, so that the command
# given to docker run is cyclictest itself, as in their scripts.
#   docker build -f Dockerfile.m4 -t rt-cyclictest:runc .
FROM rtbench-runc:alpine
RUN rm /rtbench.sh
ENTRYPOINT []
CMD ["/bin/sh"]
