#!/bin/bash
RepositoryName="RepositoryName"
region="us-west-2"

rm -rf $RepositoryName
sudo npm -g update aws-cdk
sudo conda update --all -y
sudo pip install -U pip -y
pip install git-remote-codecommit
aws codecommit delete-repository --repository-name $RepositoryName
aws codecommit create-repository --repository-name $RepositoryName

git clone "codecommit::$region://$RepositoryName"
cd $RepositoryName
pwd
ls
cdk init app --language python
python -m venv .env
source .env/bin/activate
git commit -m "Project Started"
pip install -e git+https://github.com/pypa/pip.git#egg=master
pip install --upgrade pip distribute
pip install -r requirements.txt
git remote add origin "codecommit::$region://$RepositoryName"
pip install git-remote-codecommit
pip install aws_cdk.aws_codedeploy aws_cdk.aws_lambda aws_cdk.aws_codebuild
pip install aws_cdk.aws_codecommit aws_cdk.aws_codepipeline_actions
pip install aws_cdk.aws_s3 aws_cdk.aws_codepipeline

rm -rf test
mkdir tests
git add --all
git commit -m "initial commit"
git push

mkdir lambda && cd lambda
lambda_code="//index.ts
const GREETING = 'Hello, Jake!';
export async function main(event: any, context: any) {
	console.log(GREETING);
	return GREETING;
}"
printf "%s" "$lambda_code" > index.ts
git add --all
git commit -m "add lambda function"
git push

cd ..
mkdir pipeline
cd pipeline
lambda_stack=$(cat <<-END
from aws_cdk.core import App, Stack, Construct
from aws_cdk.aws_lambda import Code, Function, Alias, Runtime
from aws_cdk.aws_codedeploy import LambdaDeploymentGroup, LambdaDeploymentConfig


class LambdaStack(Stack):
    
    def __init__(self, app: App, id: str, **kwargs):
        super().__init__(app, id, **kwargs)

        self.lambda_code = Code.from_cfn_parameters()
        self.lambda_function = Function(
            self, "LambdaFunction",
            code=self.lambda_code,
            handler="index.main",
            runtime=Runtime.NODEJS_10_X,
        )
        self.lambda_alias = Alias(
            self, "LambdaAlias", 
            alias_name="Prod",
            version=self.lambda_function.current_version
        )
        LambdaDeploymentGroup(
            self, "DeploymentGroup",
            alias=self.lambda_alias,
            deployment_config=LambdaDeploymentConfig.LINEAR_10_PERCENT_EVERY_1_MINUTE
        )
END
)
printf "%s" "$lambda_stack" > lambda_stack.py

git add --all
git commit -m "add lambda stack"
git push

pipeline_stack=$(cat <<-END
from aws_cdk.core import Stack, Construct
from aws_cdk.aws_codebuild import PipelineProject, BuildSpec, LinuxBuildImage
from aws_cdk.aws_codecommit import Repository
from aws_cdk.aws_codepipeline import Artifact, Pipeline, StageProps
from aws_cdk.aws_codepipeline_actions import CodeCommitSourceAction, CodeBuildAction, CloudFormationCreateUpdateStackAction
from aws_cdk.aws_lambda import CfnParametersCode


class PipelineStack(Stack):

    def __init__(self, scope: Construct, id: str, *, repo_name: str=None,
        lambda_code: CfnParametersCode=None, 
        lambda_stack_name=None, **kwargs,) -> None:
        super().__init__(scope, id, **kwargs)

        if not lambda_stack_name:
            raise ValueError("Lambda Stack Name required")
        
        lambda_stack_file = f"{lambda_stack_name}.template.json"

        cdk_build = PipelineProject(
            self, "CDKBuild",
            build_spec=BuildSpec.from_object(
                dict(
                    version="0.2",
                    phases=dict(
                        install=dict(
                            commands=[
                                "npm install aws-cdk",
                                "npm update",
                                "python -m pip install -r requirements.txt"
                            ]
                        ),
                        build=dict(
                            commands=[
                                "npx cdk synth -o dist"
                            ]
                        )                        
                    ),
                    artifacts={
                            "base-directory": "dist",
                            "files": [
                                lambda_stack_file
                            ]
                        },
                    environment=dict(
                        buildImage=LinuxBuildImage.STANDARD_2_0
                    )
                )
            )
        )

        lambda_build = PipelineProject(
            self, "LambdaBuild",
            build_spec=BuildSpec.from_object(
                dict(
                    version="0.2",
                    phases=dict(
                        install=dict(
                            commands=[
                                "cd lambda",
                                "npm install",
                                "npm install typescript"
                            ]
                        ),
                        build=dict(
                            commands=[
                                "npx tsc index.ts"
                            ]
                        )
                    ),
                    artifacts={
                        "base-directory": "lambda",
                        "files": [
                            "index.js",
                            "node_modules/**/*"
                        ]
                    },
                    environment=dict(
                        buildImage=LinuxBuildImage.STANDARD_2_0
                    )
                )
            )
        )

        source_output = Artifact()
        cdk_build_output = Artifact("CdkBuildOutput")
        lambda_build_output = Artifact("LambdaBuildOutput")

        lambda_location = lambda_build_output.s3_location

        code = Repository.from_repository_name(
            self, "ImportedRepository",
            repo_name
        )

        Pipeline(
            self, "Pipeline",
            stages=[
                StageProps(
                    stage_name="Source",
                    actions=[
                        CodeCommitSourceAction(
                            action_name="CodeCommit_Source",
                            repository=code,
                            output=source_output
                        )
                    ]
                ),
                StageProps(
                    stage_name="Build",
                    actions=[
                        CodeBuildAction(
                            action_name="Lambda_Build",
                            project=lambda_build,
                            input=source_output,
                            outputs=[lambda_build_output]
                        ),
                        CodeBuildAction(
                            action_name="CDK_Build",
                            project=cdk_build,
                            input=source_output,
                            outputs=[cdk_build_output]
                        )
                    ]
                ),
                StageProps(
                    stage_name="Deploy",
                    actions=[
                        CloudFormationCreateUpdateStackAction(
                            action_name="Lambda_CFN_Deploy",
                            template_path=cdk_build_output.at_path(lambda_stack_file),
                            stack_name=lambda_stack_name,
                            admin_permissions=True,
                            parameter_overrides=dict(
                                lambda_code.assign(
                                    bucket_name=lambda_location.bucket_name,
                                    object_key=lambda_location.object_key,
                                    object_version=lambda_location.object_version
                                )
                            ),
                            extra_inputs=[lambda_build_output]
                        )
                    ]
                )
            ]
        )
END
)
printf "%s" "$pipeline_stack" > pipeline_stack.py
git add --all
git commit -m "add pipeline stack"
git push


cd ..
app=$(cat <<-END
CODECOMMIT_REPO_NAME = "$RepositoryName"

from aws_cdk.core import App
from pipeline.pipeline_stack import PipelineStack
from pipeline.lambda_stack import LambdaStack

app = App()
lambda_stack_name = "LambdaDeploymentStack"
lambda_stack = LambdaStack(app, lambda_stack_name)
PipelineStack(
    app, "PipelineDeployingLambdaStack",
    lambda_code=lambda_stack.lambda_code,
    lambda_stack_name=lambda_stack_name,
    repo_name=CODECOMMIT_REPO_NAME,
)
app.synth()
END
)
printf "%s" "$app" > app.py

git add --all
git commit -m "add CDK app"
git push

pip freeze | grep -v '-e git' > requirements.txt
git add .
git commit -m "Modify requirements.txt"
git push

cdk ls
cdk deploy "Pipe*"
