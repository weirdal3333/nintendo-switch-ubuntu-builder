pipeline {
    agent any

    stages {
        stage('Build') {
            steps {
                echo 'Building...'
                sh './build-image.sh'
            }
        }
    }
}
