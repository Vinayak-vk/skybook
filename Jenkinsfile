// SkyBook CI/CD (multibranch: runs for every branch and pull request).
//
//   every branch + PR : unit tests -> source scan -> build images -> scan images
//   main only         : push images -> commit new staging tags (GitOps)
//                       -> wait until staging serves the new version
//
// Production is promoted separately by the "skybook-promote" job
// (ci/jenkins/promote.Jenkinsfile). The pipeline never talks to the cluster:
// Argo CD pulls the desired state from git, so no kubeconfig lives in Jenkins.

def SERVICES = ['frontend', 'flight-search', 'booking-api']

pipeline {
  agent none

  options {
    buildDiscarder(logRotator(numToKeepStr: '20'))
    // Queue rather than abort: the GitOps commit below triggers a new build of
    // main, which must not kill this one while it is verifying staging.
    disableConcurrentBuilds()
    timestamps()
  }

  environment {
    REGISTRY    = 'ghcr.io/vinayak-vk'
    STAGING_URL = 'https://staging.skybook-vinayak.duckdns.org'
  }

  stages {
    stage('CI') {
      agent {
        kubernetes {
          yamlFile 'ci/jenkins/build-pod.yaml'
          defaultContainer 'jnlp'
        }
      }

      stages {
        stage('Prepare') {
          steps {
            script {
              env.TAG = sh(script: 'git rev-parse --short=12 HEAD', returnStdout: true).trim()
              // Commits pushed by this pipeline carry [skip ci]; building them
              // again would loop forever.
              def message = sh(script: 'git log -1 --pretty=%B', returnStdout: true)
              env.SKIP_CI = message.contains('[skip ci]') ? 'true' : 'false'
              currentBuild.description = env.SKIP_CI == 'true' ? 'GitOps commit, skipped' : "tag ${env.TAG}"
            }
            // Created here (as the agent user) so every container can write to it.
            sh 'mkdir -p .ci'
          }
        }

        stage('Unit tests') {
          when { expression { env.SKIP_CI == 'false' } }
          parallel {
            stage('booking-api') {
              steps {
                container('python') {
                  dir('services/booking-api') {
                    sh '''
                      python -m venv /tmp/venv
                      . /tmp/venv/bin/activate
                      pip install --quiet --requirement requirements-dev.txt
                      ruff check .
                      pytest --junitxml=test-results.xml --cov=app --cov-report=term-missing
                    '''
                  }
                }
              }
              post {
                always {
                  junit allowEmptyResults: true, testResults: 'services/booking-api/test-results.xml'
                }
              }
            }
            stage('flight-search') {
              steps {
                container('node') {
                  dir('services/flight-search') {
                    sh 'npm ci --no-audit --no-fund && npm test'
                  }
                }
              }
            }
          }
        }

        stage('Source scan') {
          when { expression { env.SKIP_CI == 'false' } }
          steps {
            container('trivy') {
              // Gate: fixable CRITICAL CVEs in dependencies, or leaked secrets.
              sh '''
                trivy fs --scanners vuln,secret --severity CRITICAL --ignore-unfixed \
                  --exit-code 1 --skip-dirs services/flight-search/node_modules .
              '''
              // Report only: misconfigurations in Dockerfiles, Helm, Kubernetes
              // and Terraform. Archived with the build.
              sh '''
                trivy config --severity HIGH,CRITICAL --exit-code 0 \
                  --helm-values deploy/envs/staging/values.yaml \
                  --output trivy-misconfig.txt . \
                  || echo "Misconfiguration scan did not complete; see the log above."
              '''
            }
          }
          post {
            always {
              archiveArtifacts artifacts: 'trivy-misconfig.txt', allowEmptyArchive: true
            }
          }
        }

        stage('Build & scan images') {
          when { expression { env.SKIP_CI == 'false' } }
          steps {
            withCredentials([usernamePassword(credentialsId: 'github-token', usernameVariable: 'GH_USER', passwordVariable: 'GH_TOKEN')]) {
              container('buildkit') {
                sh 'sh ci/scripts/registry-login.sh'
              }
            }
            script {
              for (svc in SERVICES) {
                container('buildkit') {
                  sh "sh ci/scripts/build-image.sh ${svc} oci"
                }
                container('trivy') {
                  // Gate: nothing ships with a fixable CRITICAL vulnerability.
                  sh "trivy image --input .ci/${svc}.tar --severity CRITICAL --ignore-unfixed --exit-code 1"
                  sh "trivy image --input .ci/${svc}.tar --format cyclonedx --output .ci/sbom-${svc}.cdx.json"
                }
              }
            }
          }
          post {
            always {
              archiveArtifacts artifacts: '.ci/sbom-*.cdx.json', allowEmptyArchive: true
            }
          }
        }

        stage('Publish images') {
          when {
            allOf {
              branch 'main'
              expression { env.SKIP_CI == 'false' }
            }
          }
          steps {
            container('buildkit') {
              script {
                // Same inputs as the scanned build, so this is served from cache.
                for (svc in SERVICES) {
                  sh "sh ci/scripts/build-image.sh ${svc} push"
                }
              }
            }
          }
        }

        stage('Deploy to staging') {
          when {
            allOf {
              branch 'main'
              expression { env.SKIP_CI == 'false' }
            }
          }
          steps {
            container('yq') {
              script {
                for (svc in SERVICES) {
                  sh "yq -i '.services.\"${svc}\".tag = \"${env.TAG}\"' deploy/envs/staging/values.yaml"
                }
              }
            }
            withCredentials([usernamePassword(credentialsId: 'github-token', usernameVariable: 'GH_USER', passwordVariable: 'GH_TOKEN')]) {
              sh "sh ci/scripts/gitops-commit.sh 'deploy(staging): ${env.TAG}'"
            }
          }
        }

        stage('Verify staging') {
          when {
            allOf {
              branch 'main'
              expression { env.SKIP_CI == 'false' }
            }
          }
          steps {
            container('yq') {
              timeout(time: 10, unit: 'MINUTES') {
                sh 'sh ci/scripts/wait-for-version.sh "$STAGING_URL" "$TAG"'
              }
            }
          }
        }
      }
    }
  }

  post {
    success {
      script {
        if (env.BRANCH_NAME == 'main' && env.SKIP_CI == 'false') {
          echo "Staging now runs ${env.TAG}. Run the 'skybook-promote' job to ship it to production."
        }
      }
    }
  }
}
