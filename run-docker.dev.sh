# !/bin/bash

# Note: env variables should be set to local-k8

make docker-clean

echo building portfolio projects locally to run in docker...

# navigate to all projects and run docker from respective root directories

# homepage
cd homepage
bash run-docker.dev.sh
echo homepage is now running...
cd ..

# react-to-do
cd portfolio/react-to-do
bash run-docker.dev.sh
echo react-to-do is now running...
cd ../..

# react-electoral-map
cd portfolio/react-electoral-map
bash run-docker.dev.sh
echo react-electoral-map is now running...
cd ../..

# react-course-admin
cd portfolio/react-course-admin
bash run-docker.dev.sh
echo react-course-admin is now running...
cd ../..

# nest-blog-api
cd portfolio/nest-blog-api
bash run-docker.dev.sh
echo nest-blog-api is now running...
cd ../..

# nginx proxy server is not needed (and won't work) in local dev

echo hompeage and portfolio projects successfully built and running in docker
echo hompage is now running on: http://localhost:8080

