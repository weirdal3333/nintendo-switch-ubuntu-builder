pipeline {
    agent none
    stages {
        stage('Build') {
            agent { docker { image 'ubuntu:18.04' } }
            steps {
                echo 'Building...'
                sh 'cd /tmp/ ; git clone https://github.com:cmsj/nintendo-switch-ubuntu-builder.git && cd nintendo-switch-ubuntu-builder && ./build-image.sh'
            }
        }
    }
}
