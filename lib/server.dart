library bloodless_server;

import 'dart:async';
import 'dart:io';
import 'dart:mirrors';
import 'dart:convert' as conv;

import 'package:http_server/http_server.dart';
import 'package:route_hierarchical/url_matcher.dart';
import 'package:route_hierarchical/url_template.dart';
import 'package:logging/logging.dart';

const String GET = "GET";
const String POST = "POST";

const String JSON = "application/json";
const String FORM = "form";
const String TEXT = "text/plain";

const String _DEFAULT_ADDRESS = "0.0.0.0";
const int _DEFAULT_PORT = 8080;

final Logger _logger = new Logger("bloodless_server");


class Route {
  
  final String urlTemplate;
  
  final List<String> methods;

  final String responseType;

  const Route(String this.urlTemplate, 
              {this.methods: const [GET],
               this.responseType});

  Route._fromGroup(String this.urlTemplate, 
              this.methods, this.responseType);

}

class Body {

  final String type;

  const Body(String this.type);

}

class FormParam {

  final String name;

  const FormParam(String this.name);

}

class QueryParam {
  
  final String name;

  const QueryParam(String this.name);
}


class Interceptor {

  final String urlPattern;
  final int chainIdx;

  const Interceptor(String this.urlPattern, {int this.chainIdx: 0});

  Interceptor._fromGroup(String this.urlPattern, int this.chainIdx);

}

class ErrorHandler {

  final int statusCode;

  const ErrorHandler(int this.statusCode);

}

class Group {

  final String urlPrefix;

  const Group(String this.urlPrefix);

}

class Request {

  HttpRequestBody _reqBody;
  Map<String, String> _queryParams;

  Request(HttpRequestBody this._reqBody,
          Map<String, String> this._queryParams);

  String get method => _reqBody.request.method;

  Map<String, String> get queryParams => _queryParams;

  String get bodyType => _reqBody.type;

  dynamic get body => _reqBody.body;

  HttpHeaders get headers => _reqBody.request.headers;

  HttpSession get session => _reqBody.request.session;

  HttpResponse get response => _reqBody.request.response;

  HttpRequest get httpRequest => _reqBody.request;

}

abstract class Chain {

  Future next();

  void interrupt(int statusCode, {Object response, String responseType});

}

class _ChainImpl implements Chain {

  List<_Interceptor> _interceptors;
  _Interceptor _currentInterceptor;
  
  bool _targetInvoked = false;
  bool _interrupted = false;

  List _completers = [];

  _ChainImpl(List<_Interceptor> this._interceptors);

  Future next() {
    return new Future.sync(() {
      if (_interrupted) {
        var name = _currentInterceptor != null ? _currentInterceptor.interceptorName : null;
        throw new ChainException(request.httpRequest.uri.path, 
                                 "invalid state: chain already interrupted",
                                 interceptorName: name);
      }
      if (_interceptors.isEmpty && _targetInvoked) {
        throw new ChainException(request.httpRequest.uri.path, "chain.next() must be called from an interceptor.");
      }

      Completer completer = new Completer();
      _completers.add(completer);

      if (!_interceptors.isEmpty) {
        _currentInterceptor = _interceptors.removeAt(0);
        new Future(() {
          _currentInterceptor.runInterceptor();
        });
      } else {
        _targetInvoked = true;
        _runTarget(request._reqBody).then((_) {
          _completers.reversed.forEach((c) => c.complete());
        });
      }

      return completer.future;
    });
  }

  void interrupt(int statusCode, {Object response, String responseType}) {
    _interrupted = true;

    _writeResponse(response, request.response, responseType, statusCode: statusCode);
  }

}


class SetupException implements Exception {

  final String handler;
  final String message;

  SetupException(String this.handler, String this.message);

  String toString() => "SetupException: [$handler] $message";

}

class RequestException implements Exception {
  
  final String handler;
  final String message;

  RequestException(String this.handler, String this.message);

  String toString() => "RequestException: [$handler] $message";
}

class ChainException implements Exception {
  
  final String urlPath;
  final String interceptorName;
  final String message;

  ChainException(String this.urlPath, String this.message, {String this.interceptorName});

  String toString() => message;

}



Request get request => Zone.current[#request];

Chain get chain => Zone.current[#chain];


Future<HttpServer> start([address = _DEFAULT_ADDRESS, int port = _DEFAULT_PORT]) {
  return new Future(() {
    
    try {
      _scanHandlers();
    } catch (e) {
      _handleError("Failed to configure handlers.", e);
      throw e;
    }

    return HttpServer.bind(address, port).then((server) {
      server.transform(new HttpBodyHandler())
          .listen((HttpRequestBody req) {

            _logger.fine("Received request for: ${req.request.uri}");
            _handleRequest(req);

          });

      _logger.info("Running on $address:$port");
      return server;
    });
  });
}

void attach(httpRequest) {

}

var _intType = reflectClass(int);
var _doubleType = reflectClass(double);
var _boolType = reflectClass(bool);
var _stringType = reflectClass(String);
var _dynamicType = reflectType(dynamic);
var _voidType = currentMirrorSystem().voidType;

final List<_Target> _targets = [];
final List<_Interceptor> _interceptors = [];

void _handleRequest(HttpRequestBody req) {

  var queryParams = req.request.uri.queryParameters;
  var path = req.request.uri.path;
  var handlers = _interceptors.where((i) => i.urlPattern.firstMatch(path)[0] == path);
  var chain = new _ChainImpl(new List.from(handlers));

  runZoned(() {

    chain.next().then((_) {
      request.response.close();
      _logger.finer("Closed request for: ${request.httpRequest.uri}");
    });

  }, zoneValues: {
    #request: new Request(req, queryParams),
    #chain: chain
  }, onError: (e, s) {
    _handleError("Failed to handle request.", e, stack: s, req: req);
  });
}

void _handleError(String message, Object error, {StackTrace stack, HttpRequestBody req}) {
  _logger.severe(error, stack);

  if (req != null) {
    try {
      var resp = req.request.response;

      if (error is RequestException) {
        resp.statusCode = HttpStatus.BAD_REQUEST;
      } else {
        resp.statusCode = HttpStatus.INTERNAL_SERVER_ERROR;
      }

      resp.close();
    } catch(e) {
      _logger.severe(e);
    }
  }
}

Future _runTarget(HttpRequestBody req) {

  return new Future.sync(() {

    Future f = null;
    for (var target in _targets) {
      f = target.handleRequest(req);
      if (f != null) {
        break;
      }
    }

    if (f == null) {
      try {
        var resp = req.request.response;
        resp.statusCode = HttpStatus.NOT_FOUND;

        _logger.fine("Resource not found: ${req.request.uri}");
      } catch(e) {
        _handleError("Failed to send response to user.", e);
      }
    }

    return f;

  });

}

typedef Future _RequestHandler(UrlMatch match, HttpRequestBody request);
typedef void _RunInterceptor();

typedef _TargetParam _ParamProcessor(Map<String, String> urlParams,
                                     Map<String, String> queryParams, 
                                     String bodyType, dynamic reqBody);

typedef dynamic _ConvertFunction(String value);

class _Target {
  
  final UrlTemplate urlTemplate;
  final _RequestHandler handler;

  _Target(this.urlTemplate, this.handler);

  Future handleRequest(HttpRequestBody req) {
    UrlMatch match = urlTemplate.match(req.request.uri.path);
    if (match == null || !match.tail.isEmpty) {
      return null;
    }

    return handler(match, req);
  }
}

class _TargetParam {

  final dynamic value;
  final Symbol name;

  _TargetParam(this.value, [this.name]);

}

class _Interceptor {
  
  final RegExp urlPattern;
  final String interceptorName;
  final int chainIdx;
  final _RunInterceptor runInterceptor;

  _Interceptor(this.urlPattern, this.interceptorName, 
               this.chainIdx, this.runInterceptor);

}


void _scanHandlers() {
  currentMirrorSystem().libraries.values.forEach((LibraryMirror lib) {

    lib.topLevelMembers.values.forEach((MethodMirror method) {
      method.metadata.forEach((InstanceMirror metadata) {
        if (metadata.reflectee is Route) {
          _configureTarget(metadata.reflectee as Route, lib, method);
        } else if (metadata.reflectee is Interceptor) {
          _configureInterceptor(metadata.reflectee as Interceptor, lib, method);
        }
      });
    });

    lib.declarations.values.forEach((DeclarationMirror declaration) {
      if (declaration is ClassMirror) {
        ClassMirror clazz = declaration as ClassMirror;

        clazz.metadata.forEach((InstanceMirror metadata) {
          if (metadata.reflectee is Group) {
            _configureGroup(metadata.reflectee as Group, clazz);
          }
        });
      }
    });
  });

  _interceptors.sort((i1, i2) => i1.chainIdx - i2.chainIdx);
}

void _configureGroup(Group group, ClassMirror clazz) {

  var className = MirrorSystem.getName(clazz.qualifiedName);
  _logger.info("Found group: " + className);

  InstanceMirror instance = null;
  try {
    instance = clazz.newInstance(new Symbol(""), []);
  } catch(e) {
    throw new SetupException(className, "Failed to create a instance of the group. Does $className have a default constructor with no arguments?");
  }

  String prefix = group.urlPrefix;
  if (prefix.endsWith("/")) {
    prefix = prefix.substring(0, prefix.length - 1);
  }

  clazz.instanceMembers.values.forEach((MethodMirror method) {

    method.metadata.forEach((InstanceMirror metadata) {
      if (metadata.reflectee is Route) {
        
        Route route = metadata.reflectee as Route;
        String urlTemplate = route.urlTemplate;
        if (!urlTemplate.startsWith("/")) {
          urlTemplate = "$prefix/$urlTemplate";
        } else {
          urlTemplate = "$prefix$urlTemplate";
        }
        var newRoute = new Route._fromGroup(urlTemplate, route.methods, route.responseType);

        _configureTarget(newRoute, instance, method);
      } else if (metadata.reflectee is Interceptor) {

        Interceptor interceptor = metadata.reflectee as Interceptor;
        String urlPattern = interceptor.urlPattern;
        if (!urlPattern.startsWith("/")) {
          urlPattern = "$prefix/$urlPattern";
        } else {
          urlPattern = "$prefix$urlPattern";
        }
        var newInterceptor = new Interceptor._fromGroup(urlPattern, interceptor.chainIdx);

        _configureInterceptor(newInterceptor, instance, method);
      }
    });

  });
}

void _configureInterceptor(Interceptor interceptor, ObjectMirror owner, MethodMirror handler) {

  var handlerName = MirrorSystem.getName(handler.qualifiedName);
  if (!handler.parameters.where((p) => !p.isOptional).isEmpty) {
    throw new SetupException(handlerName, "Interceptors must have no required arguments.");
  }

  var caller = () {

    _logger.finer("Invoking interceptor: $handlerName");
    owner.invoke(handler.simpleName, []);

  };

  var name = MirrorSystem.getName(handler.qualifiedName);
  _interceptors.add(new _Interceptor(new RegExp(interceptor.urlPattern), name,
                                     interceptor.chainIdx, caller));

  _logger.info("Configured interceptor for ${interceptor.urlPattern} : $handlerName");
}

void _configureTarget(Route route, ObjectMirror owner, MethodMirror handler) {

  var paramProcessors = _buildParamProcesors(handler);
  var handlerName = MirrorSystem.getName(handler.qualifiedName);

  var caller = (UrlMatch match, HttpRequestBody request) {
    
    _logger.finer("Preparing to execute target: $handlerName");

    return new Future.sync(() {

      var httpResp = request.request.response;
      var pathParams = match.parameters;
      var queryParams = request.request.uri.queryParameters;

      if (!route.methods.contains(request.request.method)) {
        httpResp.statusCode = HttpStatus.METHOD_NOT_ALLOWED;
        return null;
      }
      
      var posParams = [];
      var namedParams = {};
      paramProcessors.map((f) => 
          f(pathParams, queryParams, request.type, request.body))
            .forEach((_TargetParam targetParam) {
              if (targetParam.name == null) {
                posParams.add(targetParam.value);
              } else {
                namedParams[targetParam.name] = targetParam.value;
              }
            });

      _logger.finer("Invoking target $handlerName");
      InstanceMirror resp = owner.invoke(handler.simpleName, posParams, namedParams);

      if (resp.type == _voidType) {
        return null;
      }

      var respValue = resp.reflectee;

      _logger.finer("Writing response for target $handlerName");
      return _writeResponse(respValue, httpResp, route.responseType);

    });    

  };

  _targets.add(new _Target(new UrlTemplate(route.urlTemplate), caller));

  _logger.info("Configured target for ${route.urlTemplate} : $handlerName");
}

Future _writeResponse(respValue, HttpResponse httpResp, String responseType, {int statusCode}) {

  return new Future.sync(() {

    if (respValue == null) {

      if (statusCode != null) {
        httpResp.statusCode = statusCode;
      }
      return null;

    } else if (respValue is Future) {

      return (respValue as Future).then((fValue) {
        _writeResponse(fValue, httpResp, responseType);
      });

    } else if (respValue is Map || respValue is List) {

      if (statusCode != null) {
        httpResp.statusCode = statusCode;
      }
      respValue = conv.JSON.encode(respValue);
      if (responseType != null) {
        httpResp.headers.add(HttpHeaders.CONTENT_TYPE, responseType);
      } else {
        httpResp.headers.contentType = new ContentType("application", "json", charset: "UTF-8");
      }
      httpResp.write(respValue);
      return null;

    } else {

      if (statusCode != null) {
        httpResp.statusCode = statusCode;
      }
      if (responseType != null) {
        httpResp.headers.add(HttpHeaders.CONTENT_TYPE, responseType);
      } else {
        httpResp.headers.contentType = new ContentType("text", "plain");
      }
      httpResp.write(respValue);
      return null;

    }

  });

}

List<_ParamProcessor> _buildParamProcesors(MethodMirror handler) {
  
  var bodyParam = false;
  var bodyType = null;

  return new List.from(handler.parameters.map((ParameterMirror param) {
    var handlerName = MirrorSystem.getName(handler.qualifiedName);
    var paramSymbol = param.simpleName;
    var name = param.isNamed ? paramSymbol : null;

    if (!param.metadata.isEmpty) {
      var metadata = param.metadata[0];

      if (metadata.reflectee is Body) {

        var body = metadata.reflectee as Body;
        if (bodyParam) {
          throw new SetupException(handlerName, "Invalid parameters: Only one parameter can be annotated with @Body");
        } else if (bodyType != null && bodyType != body.type) {
          var paramName = MirrorSystem.getName(paramSymbol);
          throw new SetupException(handlerName, "Invalid parameters: $paramName is accesing the request's body as ${body.type}, "
              "but a previous parameter is acessing the body as $bodyType");
        }
        bodyParam = true;
        bodyType = body.type;

        return (urlParams, queryParams, reqBodyType, reqBody) {
          if (bodyType != reqBodyType) {
            throw new RequestException(handlerName, "$reqBodyType data not supported for this target");
          } 
          return new _TargetParam(reqBody, name);
        };

      } else if (metadata.reflectee is FormParam) {
        var paramName = MirrorSystem.getName(paramSymbol);
        if (bodyType != null && bodyType != FORM) {
          throw new SetupException(handlerName, "Invalid parameters: $paramName is accesing the request's body as $FORM, "
              "but a previous parameter is acessing the body as $bodyType");
        }

        var convertFunc = _buildConvertFunction(param.type);

        return (urlParams, queryParams, reqBodyType, reqBody) {
          if (bodyType != reqBodyType) {
            throw new RequestException(handlerName, "$reqBodyType data not supported for this target");
          } 
          var value = (reqBody as Map)[(metadata.reflectee as FormParam).name];
          if (value != null) {
            try {
              value = convertFunc(value);
            } catch(e) {
              throw new RequestException(handlerName, "Invalid value for $paramName: $value");
            }
          }
          return new _TargetParam(value, name);
        };
      } else if (metadata.reflectee is QueryParam) {
        var paramName = MirrorSystem.getName(paramSymbol);
        var convertFunc = _buildConvertFunction(param.type);

        return (urlParams, queryParams, reqBodyType, reqBody) {
          var value = (reqBody as Map)[(metadata.reflectee as QueryParam).name];
          if (value != null) {
            try {
              value = convertFunc(value);
            } catch(e) {
              throw new RequestException(handlerName, "Invalid value for $paramName: $value");
            }
          }
          return new _TargetParam(value, name);
        };
      }
    }

    var convertFunc = _buildConvertFunction(param.type);
    var paramName = MirrorSystem.getName(paramSymbol);

    return (urlParams, queryParams, reqBodyType, reqBody) {
      var value = urlParams[paramName];
      if (value != null) {
        value = convertFunc(value);
      }
      return new _TargetParam(value, name);
    };
  }));
}

_ConvertFunction _buildConvertFunction(paramType) {
  if (paramType == _stringType || paramType == _dynamicType) {
    return (String value) => value;
  }
  if (paramType == _intType) {
    return (String value) => int.parse(value);
  }
  if (paramType == _doubleType) {
    return (String value) => double.parse(value);
  }
  if (paramType == _boolType) {
    return (String value) => value.toLowerCase() == "true";
  }
}