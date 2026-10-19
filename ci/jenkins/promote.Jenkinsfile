// Promotes exactly what is running in staging to production.
//
// Started by hand from the "skybook-promote" job: it shows the tag changes,
// waits for an explicit approval, commits the new prod tags, then watches the
// Argo Rollouts canary until production serves the new version. If the canary
// analysis fails, Argo Rollouts rolls back and the 'Canary' stage times out red.

def SERVICES = ['frontend', 'flight-search', 'booking-api']

def readTag(String environment, String service) {
  def tag = ''
  container('yq') {
    tag = sh(script: "yq '.services.\"${service}\".tag' deploy/envs/${environment}/values.yaml", returnStdout: true).trim()
  }
  return tag
}

pipeline {
  agent {
    kubernetes {
      yamlFile 'ci/jenkins/promote-pod.yaml'
      defaultContainer 'jnlp'
    }
  }

  options {
    buildDiscarder(logRotator(numToKeepStr: '30'))
    disableConcurrentBuilds()
    timestamps()
  }

  environment {
    PROD_URL = 'https://skybook-vinayak.duckdns.org'
  }

  stages {
    stage('Plan') {
      steps {
        script {
          def lines = []
          for (svc in SERVICES) {
            lines << "${svc}: ${readTag('prod', svc)} -> ${readTag('staging', svc)}"
          }
          env.PLAN = lines.join('\n')
          env.TAG = readTag('staging', 'booking-api')
          echo "Promotion plan:\n${env.PLAN}"
          currentBuild.description = "prod -> ${env.TAG}"
        }
      }
    }

    stage('Approve') {
      steps {
        timeout(time: 30, unit: 'MINUTES') {
          input message: "Promote to production?\n${env.PLAN}", ok: 'Promote'
        }
      }
    }

    stage('Promote') {
      steps {
        script {
          for (svc in SERVICES) {
            def tag = readTag('staging', svc)
            container('yq') {
              sh "yq -i '.services.\"${svc}\".tag = \"${tag}\"' deploy/envs/prod/values.yaml"
            }
          }
        }
        withCredentials([usernamePassword(credentialsId: 'github-token', usernameVariable: 'GH_USER', passwordVariable: 'GH_TOKEN')]) {
          sh "sh ci/scripts/gitops-commit.sh 'deploy(prod): ${env.TAG}'"
        }
      }
    }

    stage('Canary') {
      steps {
        container('yq') {
          // 50% of pods -> 2 min pause -> error-ratio analysis -> 100%.
          timeout(time: 15, unit: 'MINUTES') {
            sh 'sh ci/scripts/wait-for-version.sh "$PROD_URL" "$TAG"'
          }
        }
      }
    }
  }
}
