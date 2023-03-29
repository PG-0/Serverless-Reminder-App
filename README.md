# Serverless-Reminder-App

## About
This is a serverless app that utilizes a front end S3 website that would trigger an API to send a reminder email after a user determined amount of time. 

AWS Services used are: S3, API Gateway, Lambda, Simple Email Service (SES), Step Functions 

## Architecture Diagram
![Architecture-ServerlessReminderApp](https://user-images.githubusercontent.com/12003721/225798059-af163cb2-d904-4dc9-ae69-6d4d5583e93f.png)

## Current Issues
The terraform code deploys all the needed infrastructure but the application is unable to make API calls due to an authorization error. Otherwise the app works fine. 

Serverless.js & API_lambda.py files get deleted after each terraform destroy.


## Unique Lessons Learned
* Content Type matters for S3. The meta data affects the behavior of the file. For example, the default content type is application/octet. This will cause the hosting of the static web page to download instead of serve to the client. 

* The use of locals in terraform. locals allows you to create a local variable. This was a part of the solution needed to fix the content type of uploaded files to S3

* Use of terraform's [resource "local_file"] to alter files. 
Example: 
    "resource "local_file" "updated_js_file" {
    filename = "${path.module}/serverless_frontend/serverless.js"
    content  = replace(data.local_file.js_file.content, "var API_ENDPOINT = 'REPLACEME_API_GATEWAY_INVOKE_URL';", "var API_ENDPOINT = 'https://${aws_api_gateway_rest_api.Reminder_App_API.id}.execute-api.us-east-1.amazonaws.com/prod/petcuddleotron';")"

This code snippit allows you to update the javascript file to set the variable to the unique ARN created via terraform. 

