# Remove exited containers
docker rm $(docker ps -aq -f status=exited) 2>/dev/null

# Remove "created" containers
docker rm $(docker ps -aq -f status=created) 2>/dev/null
