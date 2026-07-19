from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from fastapi.staticfiles import StaticFiles
from deep_translator import GoogleTranslator
import requests

app = FastAPI()
app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")

DICTIONARY_API_URL = "https://api.dictionaryapi.dev/api/v2/entries/en"

@app.get("/health")
def health_check():
    return {"status": "ok"}

@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    return templates.TemplateResponse("index.html", {"request": request, "result": None})

@app.get("/lookup/{word}")
def lookup_word(word: str):
    response = requests.get(f"{DICTIONARY_API_URL}/{word}", timeout=5)

    if response.status_code != 200:
        raise HTTPException(status_code=404, detail=f"No definition found for '{word}'")

    data = response.json()[0]

    meaning = data["meanings"][0]
    definition_entry = meaning["definitions"][0]

    definition = definition_entry.get("definition", "No definition available")
    example = definition_entry.get("example", "No example sentence available")

    try:
        urdu_meaning = GoogleTranslator(source="en", target="ur").translate(definition)
    except Exception:
        urdu_meaning = "Translation unavailable"

    return {
        "word": word,
        "part_of_speech": meaning.get("partOfSpeech", "unknown"),
        "definition": definition,
        "example": example,
        "urdu_meaning": urdu_meaning
    }