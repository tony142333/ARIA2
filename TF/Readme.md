Passcode is aria2secret


aws s3 cp s3://mybuckets123tarunv6/scripts/upload.sh ~/upload.sh --region ap-south-2 && chmod +x ~/upload.sh



aws s3 ls s3://mybuckets123tarunv6/


aws s3 rm s3://mybuckets123tarunv6/


aws s3 presign s3://mybuckets123tarunv6/  --region ap-south-2 --expires-in 2000


aws s3 sync . s3://mybuckets123tarunv6/movies/ --region ap-south-2


screen

screen -d -r

screen -r




    