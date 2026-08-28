#!/bin/sh
# The S3 driver against a real S3 server, which is not the one this box runs on.
#
# The driver is the claim that the object store is a deployment choice. A claim
# like that is worth exactly as much as the last time somebody ran it, so this
# stands up a second, different backend, provisions a bucket through the driver,
# and drives the ordinary read and write path against it.
#
# MinIO rather than AWS, because this needs no account, no credentials belonging
# to anybody, and no network beyond the image pull. It speaks the same API, and
# "anything S3 compatible" is most of what the driver is for.
#
# Skips rather than fails when the image cannot be pulled. A sweep that goes red
# because a registry was briefly unreachable teaches people to ignore it.
COMPOSE="docker compose --env-file .env -f deploy/compose.yml"
NET="siberian_storage"
NAME="sib-s3-verify"
USER_KEY="verifyaccesskey"
SECRET_KEY="verifysecretkey123"
BUCKET="sib-verify-$$"

fail() { echo "FAIL: $1"; exit 1; }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1
}
trap cleanup EXIT

docker rm -f "$NAME" >/dev/null 2>&1

echo "1. starting a second object store"
if ! docker run -d --name "$NAME" --network "$NET" \
      -e "MINIO_ROOT_USER=$USER_KEY" \
      -e "MINIO_ROOT_PASSWORD=$SECRET_KEY" \
      quay.io/minio/minio:latest server /data >/dev/null 2>&1; then
  echo "   could not start it, skipping. This needs one image pull."
  exit 0
fi

# Ready when it answers its own health path. Polled rather than slept at,
# because an image that has just been pulled starts slower than one that has
# not, and a fixed sleep is either wrong or wasteful.
ready=""
i=0
while [ $i -lt 30 ]; do
  if docker exec "$NAME" curl -sf http://localhost:9000/minio/health/live >/dev/null 2>&1; then
    ready="yes"
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ -n "$ready" ] || fail "the second store never became ready"
echo "   ready after ${i}s"

# Everything below runs inside the Storage service, against the driver, with the
# environment a deployment on S3 would have. Nothing here is a mock: the same
# provisioner and the same object client the product uses.
$COMPOSE exec -T \
  -e SIBERIAN_OBJECT_STORE=s3 \
  -e SIBERIAN_OBJECT_STORE_ENDPOINT="http://$NAME:9000" \
  -e SIBERIAN_OBJECT_STORE_ACCESS_KEY_ID="$USER_KEY" \
  -e SIBERIAN_OBJECT_STORE_SECRET_ACCESS_KEY="$SECRET_KEY" \
  -e SIBERIAN_OBJECT_STORE_REGION=us-east-1 \
  storage bin/rails runner "
    driver = Siberian::ObjectStore.driver
    abort('the driver is not the S3 one') unless driver.name == 's3'
    puts \"2. driver in use              -> #{driver.name}\"
    puts \"3. reachable                  -> #{driver.healthy?}\"
    abort('unreachable') unless driver.healthy?

    provisioned = driver.provision('$BUCKET')
    puts \"4. provisioned a bucket       -> #{provisioned.handle}\"
    puts \"5. credential scoped to it    -> #{provisioned.scoped?}   (expect false on S3)\"
    abort('S3 must not claim a scoped credential') if provisioned.scoped?

    # Provisioning twice is how reinstalling a module behaves.
    driver.provision('$BUCKET')
    puts '6. provisioning again          -> fine'

    bucket = Bucket.new(
      name: '$BUCKET', domain: 'verify.test',
      access_key_id: provisioned.access_key_id,
      secret_access_key: provisioned.secret_access_key
    )
    objects = StoredObjects.new(bucket)

    objects.put('public', 'hello.txt', 'bytes through a different backend',
                content_type: 'text/plain')
    puts '7. wrote an object             -> ok'

    body, type, = objects.get('public', 'hello.txt')
    puts \"8. read it back                -> #{body}\"
    abort('wrong bytes') unless body == 'bytes through a different backend'
    abort('wrong type') unless type == 'text/plain'

    _, streamed = objects.stream('public', 'hello.txt')
    abort('streaming disagreed with reading') unless streamed.to_a.join == body
    puts '9. streamed it                 -> same bytes'

    url = objects.presigned_get_url('public', 'hello.txt', expires_in: 300)
    abort('the signed URL names the wrong host') unless url.include?('$NAME:9000')
    puts '10. signed a URL               -> ok'

    require 'net/http'
    fetched = Net::HTTP.get_response(URI(url))
    puts \"11. followed it                -> #{fetched.code}\"
    abort('the signed URL did not work') unless fetched.code == '200'
    abort('the signed URL served the wrong bytes') unless fetched.body == body

    objects.delete('public', 'hello.txt')
    puts '12. deleted it                 -> ok'

    driver.deprovision(name: '$BUCKET', handle: provisioned.handle)
    puts \"13. removed the bucket         -> #{driver.exists?('$BUCKET') ? 'STILL THERE' : 'gone'}\"
    abort('the bucket survived') if driver.exists?('$BUCKET')
  " || fail "the S3 driver did not work against a real S3 server"

echo
echo "the same code, a different object store, and nothing above the driver knew."
