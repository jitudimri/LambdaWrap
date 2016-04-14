require 'aws-sdk'
require_relative 'aws_setup'

module LambdaWrap
	
	##
	# The LambdaManager simplifies creating a package, publishing it to S3, deploying a new version, and setting permissions.
	#
	# Note: The concept of an environment of the LambdaWrap gem matches an alias of AWS Lambda. 
	class LambdaManager
		
		##
		# The constructor does some basic setup
		# * Validating basic AWS configuration
		# * Creating the underlying client to interace with the AWS SDK
		def initialize()
			AwsSetup.new.validate()
			# AWS lambda client
			@client = Aws::Lambda::Client.new()
		end
		
		##
		# Packages a set of files and node modules into a deployable package.
		#
		# *Arguments*
		# [directory]		A temporary directory to copy all related files before they are packages into a single zip file.
		# [zipfile]			A path where the deployable package, a zip file, should be stored.
		# [input_filenames]	A list of file names that contain the source code.
		# [node_modules]	A list of node modules that need to be included in the package.
		def package(directory, zipfile, input_filenames, node_modules)
			
			FileUtils::mkdir_p directory
			FileUtils::mkdir_p File.join(directory, 'node_modules')

			input_filenames.each do |filename|
				FileUtils::copy_file(File.join(filename), File.join(directory, File.basename(filename)))
			end

			node_modules.each do |dir|
				FileUtils::cp_r(File.join('node_modules', dir), File.join(directory, 'node_modules'))
			end

			ZipFileGenerator.new(directory, zipfile).write
			
		end
		
		##
		# Publishes a package to S3 so it can be deployed as a lambda function.
		#
		# *Arguments*
		# [local_lambda_file]	The location of the package that needs to be deployed.
		# [bucket]				The s3 bucket where the file needs to be uploaded to.
		# [key]					The S3 path (key) where the package should be stored.
		def publish_lambda_to_s3(local_lambda_file, bucket, key)
			
			# get s3 object
			s3 = Aws::S3::Resource.new()
			obj = s3.bucket(bucket).object(key)
			
			# upload
			version_id = nil
			File.open(local_lambda_file, 'rb') do |file|
				version_id = obj.put({body: file}).version_id
			end
			raise 'Upload to S3 failed' if !version_id
			
			puts 'Uploaded object to S3 with version ' + version_id
			return version_id
			
		end
		
		##
		# Deploys a package that has been uploaded to S3.
		#
		# *Arguments*
		# [bucket]			The S3 bucket where the package can be retrieved from.
		# [key]				The S3 path (key) where the package can be retrieved from.
		# [version_id]		The version of the file on S3 to retrieve.
		# [function_name]	The name of the lambda function.
		# [handler]			The handler that should be executed for this lambda function.
		# [lambda_role]		The arn of the IAM role that should be used when executing the lambda function. 
		# [lambda_description]		The description of the lambda function. 
		def deploy_lambda(bucket, key, version_id, function_name, handler, lambda_role, lambda_description = "Deployed with LambdaWrap")
	
			# create or update function
			
			begin
				func = @client.get_function({function_name: function_name})
				func_config = @client.update_function_code({function_name: function_name, s3_bucket: bucket, s3_key: key, s3_object_version: version_id, publish: true}).data
				puts func_config
				func_version = func_config.version
				raise 'Error while publishing existing lambda function ' + function_name if !func_config.version
			rescue Aws::Lambda::Errors::ResourceNotFoundException
				func_config = @client.create_function({function_name: function_name, runtime: 'nodejs4.3', role: lambda_role, handler: handler, code: { s3_bucket: bucket, s3_key: key }, timeout: 5, memory_size: 128, publish: true, description: lambda_description}).data
				puts func_config
				func_version = func_config.version
				raise 'Error while publishing new lambda function ' + function_name if !func_config.version
			end
			
			add_api_gateway_permissions(function_name, nil)
			
			return func_version
			
		end
		
		##
		# Creates an alias for a given lambda function version.
		#
		# *Arguments*
		# [function_name]		The lambda function name for which the alias should be created.
		# [func_version]		The lambda function versino to which the alias should point.
		# [alias_name]			The name of the alias, matching the LambdaWrap environment concept.
		def create_alias(function_name, func_version, alias_name)
			
			# create or update alias
			func_alias = @client.list_aliases({function_name: function_name}).aliases.select{ |a| a.name == alias_name }.first()
			if (!func_alias)
				a = @client.create_alias({function_name: function_name, name: alias_name, function_version: func_version, description: 'created by an automated script'}).data
				puts a
			else
				a = @client.update_alias({function_name: function_name, name: alias_name, function_version: func_version, description: 'updated by an automated script'}).data
				puts a
			end
			
			add_api_gateway_permissions(function_name, alias_name)
			
		end
		
		##
		# Removes an alias for a function.
		#
		# *Arguments*
		# [function_name]	The lambda function name for which the alias should be removed.
		# [alias_name]		The alias to remove.
		def remove_alias(function_name, alias_name)
			
			@client.delete_alias({function_name: function_name, name: alias_name})
			
		end
		
		##
		# Adds permissions for API gateway to execute this function.
		#
		# *Arguments*
		# [function_name]		The function name which needs to be executed from API Gateway.
		# [env]					The environment (matching the function's alias) which needs to be executed from API Gateway. If nil, the permissions are set of the $LATEST version.  
		def add_api_gateway_permissions(function_name, env)
			# permissions to execute lambda
			suffix = (':' + env if env) || '' 
			func = @client.get_function({function_name: function_name + suffix}).data.configuration
			statement_id = func.function_name + (('-' + env if env) || '') 
			policy_exists = false
			begin
				existing_policies = @client.get_policy({function_name: func.function_arn}).data
				existing_policy = JSON.parse(existing_policies.policy)
				policy_exists = existing_policy['Statement'].select{ |s| s['Sid'] == statement_id}.any? 
			rescue Aws::Lambda::Errors::ResourceNotFoundException
			end
			
			if !policy_exists
				perm_add = @client.add_permission({function_name: func.function_arn, statement_id: statement_id, action: 'lambda:*', principal: 'apigateway.amazonaws.com'})
				puts perm_add.data
			end
		end
		
		private :add_api_gateway_permissions
		
	end

end