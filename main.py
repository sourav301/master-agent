from fastapi import FastAPI, Query

app = FastAPI()


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/chat")
def chat(name: str = Query(..., description="Your name")):
    return {"reply": f"hello  {name}"}