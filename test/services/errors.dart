library errors;

import "dart:async";

import 'package:redstone/server.dart' as app;
import 'package:shelf/shelf.dart' as shelf;

@app.Route("/wrong_method", methods: const [app.POST])
wrongMethod() => "this route accepts only POST requests";

@app.Route("/wrong_type", methods: const [app.POST])
wrongType(@app.Body(app.JSON) Map json) => "This route accepts only JSON content";

@app.Route("/wrong_value/:value")
wrongParam(int value) => value;

@app.Route("/route_error")
serverError() => throw "The client must receive a 500 status code";

@app.Route("/async_route_error")
asyncServerError() => new Future(() => 
    throw "The client must receive a 500 status code");

@app.Route("/interceptor_error")
targetInterceptorError() => "not_reached";

@app.Interceptor("/interceptor_error")
interceptorError() => throw "The client must receive a 500 status code";

@app.Route("/async_interceptor_error")
targetAsyncInterceptorError() => "target_executed ";

@app.Interceptor("/async_interceptor_error")
asyncInterceptorError() {
  app.chain.next(() => new Future(() => throw "The client must receive a 500 status code"));
}

@app.Route("/abort")
abort() {
  app.abort(500);
  return "response";
}

@app.Route("/redirect")
redirect() {
  app.redirect("/other_resource");
  return "response";
}

@app.ErrorHandler(404)
notFoundHandler() => new shelf.Response.notFound("not_found");

@app.ErrorHandler(500)
serverErrorHandler() => app.response.readAsString().then((resp) => 
    new shelf.Response.internalServerError(body: "${resp}server_error"));

@app.Route("/sub_handler")
subHandler() => throw "server_error";

@app.ErrorHandler(500, urlPattern: "/sub_handler?")
subErrorHandler() => new shelf.Response.internalServerError(
    body: "${app.chain.error} sub_error_handler");

@app.Route("/error_response")
errorResponse() => throw new app.ErrorResponse(400, "error_response");

@app.ErrorHandler(400, urlPattern: "/error_response")
handleErrorResponse() {
  return app.response.readAsString().then((resp) {
    return new shelf.Response(app.response.statusCode, 
                              body: "handling: $resp",
                              headers: app.response.headers);
  });
}