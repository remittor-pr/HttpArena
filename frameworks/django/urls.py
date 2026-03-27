from django.urls import path
from views import pipeline, baseline11, baseline2, json_endpoint, compression_endpoint, db_endpoint, async_db_endpoint, upload_endpoint

urlpatterns = [
    path('pipeline', pipeline),
    path('baseline11', baseline11),
    path('baseline2', baseline2),
    path('json', json_endpoint),
    path('compression', compression_endpoint),
    path('db', db_endpoint),
    path('async-db', async_db_endpoint),
    path('upload', upload_endpoint),
]
