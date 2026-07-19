from unittest.mock import patch, Mock
from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)


def test_health_check():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_index_page_loads():
    response = client.get("/")
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]


def test_lookup_word_success():
    mock_dictionary_response = Mock()
    mock_dictionary_response.status_code = 200
    mock_dictionary_response.json.return_value = [
        {
            "word": "test",
            "meanings": [
                {
                    "partOfSpeech": "noun",
                    "definitions": [
                        {
                            "definition": "A procedure for critical evaluation.",
                            "example": "The test went well."
                        }
                    ]
                }
            ]
        }
    ]

    with patch("app.main.requests.get", return_value=mock_dictionary_response), \
         patch("app.main.GoogleTranslator.translate", return_value="ٹیسٹ"):
        response = client.get("/lookup/test")

    assert response.status_code == 200
    data = response.json()
    assert data["word"] == "test"
    assert data["definition"] == "A procedure for critical evaluation."
    assert data["example"] == "The test went well."
    assert data["urdu_meaning"] == "ٹیسٹ"


def test_lookup_word_not_found():
    mock_dictionary_response = Mock()
    mock_dictionary_response.status_code = 404

    with patch("app.main.requests.get", return_value=mock_dictionary_response):
        response = client.get("/lookup/asdkjfhaslkdjfh")

    assert response.status_code == 404