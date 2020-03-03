import aws_cdk.core as cdk
import aws_cdk.aws_s3 as s3

class CdkTestStack(cdk.stack):

	def __init__(self, scope: cdk.Construct, id: str, **kwargs):
		super().__init__(scope, id, **kwargs)

		bucket = s3.Bucket(
			self, "Bucket", removal_policy=cdk.RemovalPolicy.DESTROY
		)


# npm add @mobileposse/auto-delete-bucket # to empty contents first